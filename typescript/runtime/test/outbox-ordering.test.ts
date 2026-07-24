// Outbox replay ORDER is deterministic within one commit. The transactional outbox backs the actor's
// mailbox: a turn produces events as rows, and recovery / the per-turn drain replays the undrained rows.
// Every row of ONE commit shares the transaction's `now()`, and `seq` is a random UUID, so ordering a replay
// by `created_at` (or `seq`) is non-deterministic — a batch that spilled a `terminate` after a `delegate`
// could come back reversed, terminating an instance the replay had not summoned yet. The fix is a monotonic
// `ordinal` (a bigserial) assigned in insertion order; both backends replay by it. These tests pin that the
// production order survives a round-trip through the store — deterministically over the Map twin (which shares
// `row-store.ts` with production), and, when a real Postgres is reachable, over `DbPersistence`'s bigserial.

import { randomUUID } from "node:crypto";
import { createAgentName } from "@katari-lang/types";
import { eq } from "drizzle-orm";
import { afterAll, describe, expect, test } from "vitest";
import { closeDb, db } from "../src/db/client.js";
import { outbox as outboxTable } from "../src/db/tables/execution.js";
import { projects } from "../src/db/tables/projects.js";
import { DbPersistence } from "../src/runtime/actor/db-persistence.js";
import type { OutboxMessage } from "../src/runtime/actor/persistence.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import type { ExternalEvent } from "../src/runtime/event/types.js";
import {
  type DelegationId,
  newDelegationId,
  newInstanceId,
  newOutboxSeq,
  type OutboxSeq,
  type ProjectId,
  toSnapshotId,
} from "../src/runtime/ids.js";

const PROJECT = "11111111-1111-4111-8111-111111111111" as ProjectId;
const RUN = newInstanceId();
const SNAPSHOT = toSnapshotId("snapshot-outbox-order");

/** A minimal, value-free outbox message keyed by its delegation, so a test can produce a recognisable order
 *  and read it back. `terminate` carries no `Value`, so its seal round-trip is the identity. */
function terminateMessage(delegation: DelegationId): OutboxMessage {
  const event: ExternalEvent = { kind: "terminate", from: "core", to: "core", run: RUN, delegation };
  return { seq: newOutboxSeq(), event };
}

/** Read the undrained outbox back as its `seq`s (the replay order the drain / recovery would see). */
async function replayOrder(persistence: StoringPersistence | DbPersistence): Promise<OutboxSeq[]> {
  let replayed: OutboxSeq[] = [];
  await persistence.load(PROJECT, async (loader) => {
    replayed = (await loader.outbox.pending()).map((message) => message.seq);
  });
  return replayed;
}

describe("outbox replay ordering (Map twin — deterministic)", () => {
  test("a delegate produced before a terminate in ONE commit replays delegate-first", async () => {
    // The precise regression the audit named: a MAX_BATCH_TURNS spill commits a `delegate` and a later
    // `terminate` in the same batch; the crash-recovery replay must not reverse them.
    const persistence = new StoringPersistence();
    const delegation = newDelegationId();
    const delegate: OutboxMessage = {
      seq: newOutboxSeq(),
      event: {
        kind: "delegate",
        from: "core",
        to: "core",
        run: RUN,
        delegation,
        target: { kind: "named", name: createAgentName("demo"), snapshot: SNAPSHOT },
        argument: null,
      },
    };
    const terminate = terminateMessage(delegation);
    await persistence.transaction(PROJECT, async (tx) => {
      await tx.outbox.produceOutbox([delegate, terminate]);
    });
    expect(await replayOrder(persistence)).toEqual([delegate.seq, terminate.seq]);
  });

  test("many events produced in one commit replay in exact production order", async () => {
    const persistence = new StoringPersistence();
    const messages = Array.from({ length: 10 }, () => terminateMessage(newDelegationId()));
    await persistence.transaction(PROJECT, async (tx) => {
      await tx.outbox.produceOutbox(messages);
    });
    expect(await replayOrder(persistence)).toEqual(messages.map((message) => message.seq));
  });

  test("ordinal is monotonic ACROSS commits and consumed rows never reorder the survivors", async () => {
    // Two commits, then drain the first commit's first row: the second commit's rows keep their (later)
    // ordinal, so they stay after the surviving first-commit row — a sequence never rewinds.
    const persistence = new StoringPersistence();
    const first = [terminateMessage(newDelegationId()), terminateMessage(newDelegationId())];
    const second = [terminateMessage(newDelegationId()), terminateMessage(newDelegationId())];
    await persistence.transaction(PROJECT, async (tx) => tx.outbox.produceOutbox(first));
    await persistence.transaction(PROJECT, async (tx) => tx.outbox.produceOutbox(second));
    const drained = first[0]?.seq;
    if (drained === undefined) throw new Error("no seeded message");
    await persistence.transaction(PROJECT, async (tx) => tx.outbox.consumeOutbox(drained));

    expect(await replayOrder(persistence)).toEqual([first[1]?.seq, second[0]?.seq, second[1]?.seq]);
  });
});

// The bigserial ordering is a Postgres behaviour (a shared sequence assigned in insertion order within a
// commit), so this runs only against a real database migrated with the `ordinal` column and skips on a bare
// CI runner — where the Map-twin suite above already pins the shared `row-store.ts` semantics.
const databaseAvailable = await (async () => {
  try {
    await db.select({ ordinal: outboxTable.ordinal }).from(outboxTable).limit(1);
    return true;
  } catch {
    return false;
  }
})();

// The pool must close whether the suite ran or skipped, or the worker lingers on the probe's socket.
afterAll(() => closeDb());

describe.skipIf(!databaseAvailable)("outbox replay ordering (DbPersistence — real bigserial)", () => {
  test("events sharing one commit's created_at replay in ordinal (production) order", async () => {
    const projectId = randomUUID() as ProjectId;
    await db.insert(projects).values({ id: projectId, name: `outbox-order-test-${projectId}` });
    try {
      const persistence = new DbPersistence(db);
      // Ten rows in one transaction all share `now()`; only the bigserial `ordinal` distinguishes them.
      const messages = Array.from({ length: 10 }, () => terminateMessage(newDelegationId()));
      await persistence.transaction(projectId, async (tx) => {
        await tx.outbox.produceOutbox(messages);
      });
      let replayed: OutboxSeq[] = [];
      await persistence.load(projectId, async (loader) => {
        replayed = (await loader.outbox.pending()).map((message) => message.seq);
      });
      expect(replayed).toEqual(messages.map((message) => message.seq));
    } finally {
      // The FK cascade reclaims the outbox rows with the project.
      await db.delete(projects).where(eq(projects.id, projectId));
    }
  });
});
