// The trace's `elided` narrowing — `GET /projects/:projectId/runs/:runId/events?elided=false`, the read
// that answers the shape of a real journal: an unserved ask is re-raised at every instance it crosses, so
// the run's trace holds one row per HOP where the reader wants one row per logical escalation. The payload
// already lives on the origin's row alone (docs/v0.1/records/2026-08-03-journal-relay-elision.md); this filter is what
// lets a reader stop seeing the copies at all.
//
// What must hold is that the SQL predicate and `isElided` — the projection's own answer, read off the same
// marks — never disagree, since they are two encodings of one rule. These run against the real Postgres
// schema (the predicate IS the thing under test) and skip when no database is reachable.

import { randomUUID } from "node:crypto";
import { createAgentName } from "@katari-lang/types";
import { inArray } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { closeDb, db } from "../src/db/client.js";
import { instances, runEvents, runs } from "../src/db/tables/execution.js";
import { projects } from "../src/db/tables/projects.js";
import { runEventsRepository } from "../src/modules/run/run-events.repository.js";
import { listRunEventsQuerySchema } from "../src/modules/run/run.schema.js";
import { type ExternalEvent, isElided, journalView } from "../src/runtime/event/types.js";
import {
  type InstanceId,
  newDelegationId,
  newEscalationId,
  newInstanceId,
  type SnapshotId,
} from "../src/runtime/ids.js";

const ASK = createAgentName("ask_value");
const SNAPSHOT = "snapshot-elided-filter" as SnapshotId;

const databaseAvailable = await (async () => {
  try {
    await db.select({ seq: runEvents.seq }).from(runEvents).limit(1);
    return true;
  } catch {
    return false;
  }
})();

// The pool must close whether the suite ran or skipped, or the worker lingers on the probe's socket.
afterAll(() => closeDb());

// No database needed for the wire half, and it is the half a plain boolean would get wrong: a query string
// carries "false", which is a truthy string everywhere except in a decoder that reads it.
test("the query string's `elided=false` decodes to false, not to a truthy string", () => {
  expect(listRunEventsQuerySchema.parse({ elided: "false" }).elided).toBe(false);
  expect(listRunEventsQuerySchema.parse({ elided: "true" }).elided).toBe(true);
  expect(listRunEventsQuerySchema.parse({}).elided).toBeUndefined();
  expect(listRunEventsQuerySchema.safeParse({ elided: "nope" }).success).toBe(false);
});

describe.skipIf(!databaseAvailable)("run trace — the elided filter", () => {
  const projectId = randomUUID();

  /** A run is its permanent api-side instance, so a run row needs that instance row first. */
  async function createRun(): Promise<InstanceId> {
    const runId = newInstanceId();
    await db.insert(instances).values({ id: runId, projectId, kind: "api", status: "running" });
    await db
      .insert(runs)
      .values({ id: runId, projectId, name: `run-${runId}`, qualifiedName: "main" });
    return runId;
  }

  /** One logical escalation as the journal really holds it: the origin's escalate, one relay hop's copy,
   *  the two acks that answer them, and a delegate that is neither. Every row goes through `journalView`,
   *  the same redaction the commit applies, so the fixture is the write path's own output. */
  function chain(runId: InstanceId): ExternalEvent[] {
    const origin = newEscalationId();
    const relay = newEscalationId();
    const delegation = newDelegationId();
    const argument = { kind: "string" as const, value: "the whole conversation history" };
    const wire: ExternalEvent[] = [
      {
        kind: "delegate",
        delegation,
        target: { kind: "named", name: createAgentName("middle"), snapshot: SNAPSHOT },
        argument: null,
        from: "core",
        to: "core",
        run: runId,
      },
      {
        kind: "escalate",
        delegation,
        escalation: origin,
        ask: { kind: "request", request: ASK, argument },
        from: "core",
        to: "core",
        run: runId,
      },
      {
        kind: "escalate",
        delegation,
        escalation: relay,
        ask: { kind: "request", request: ASK, argument },
        relayOf: origin,
        from: "core",
        to: "core",
        run: runId,
      },
      {
        kind: "escalateAck",
        delegation,
        escalation: relay,
        value: argument,
        relayed: true,
        from: "core",
        to: "core",
        run: runId,
      },
      {
        kind: "escalateAck",
        delegation,
        escalation: origin,
        value: argument,
        from: "core",
        to: "core",
        run: runId,
      },
    ];
    return wire.map(journalView);
  }

  async function seedChain(runId: InstanceId): Promise<void> {
    await db
      .insert(runEvents)
      .values(chain(runId).map((event) => ({ projectId, runId, event })));
  }

  beforeAll(async () => {
    // A throwaway project for the FK chain; the afterAll delete cascades everything below it away.
    await db.insert(projects).values({ id: projectId, name: `run-events-filter-test-${projectId}` });
  });

  afterAll(async () => {
    await db.delete(projects).where(inArray(projects.id, [projectId]));
  });

  test("omitted, the page is the whole trace — every hop, as before the filter existed", async () => {
    const runId = await createRun();
    await seedChain(runId);

    const { rows, total } = await runEventsRepository.browse(db, projectId, runId, 0, {
      limit: 100,
    });
    expect(total).toBe(5);
    expect(rows.filter((row) => isElided(row.event))).toHaveLength(2);
  });

  test("`false` keeps the origins, `true` keeps their copies, and the two partition the trace", async () => {
    const runId = await createRun();
    await seedChain(runId);

    const origins = await runEventsRepository.browse(db, projectId, runId, 0, {
      limit: 100,
      elided: false,
    });
    const copies = await runEventsRepository.browse(db, projectId, runId, 0, {
      limit: 100,
      elided: true,
    });

    // The predicate and `isElided` are two encodings of one rule, so each page must agree with the
    // projection's own answer on every row it returned — that is the coupling this suite exists for.
    expect(origins.rows.every((row) => !isElided(row.event))).toBe(true);
    expect(copies.rows.every((row) => isElided(row.event))).toBe(true);
    // A delegate carries no relay mark at all, so it belongs to the origins side rather than falling
    // out of both.
    expect(origins.total).toBe(3);
    expect(copies.total).toBe(2);
    // `total` is what sizes the console's pager, so it must be filtered the same way the rows are.
    expect(origins.total).toBe(origins.rows.length);
    expect(copies.total).toBe(copies.rows.length);
  });

  test("it composes with `kind`, and narrows the tail the same way it narrows a page", async () => {
    const runId = await createRun();
    await seedChain(runId);

    const escalates = await runEventsRepository.browse(db, projectId, runId, 0, {
      limit: 100,
      kind: "escalate",
      elided: false,
    });
    expect(escalates.total).toBe(1);
    expect(escalates.rows[0]?.event.kind).toBe("escalate");

    // The keyset tail shares `filterConditions`, so a watcher polling for origins sees the same set.
    const tailed = await runEventsRepository.tail(db, projectId, runId, 0, {
      limit: 100,
      elided: false,
    });
    expect(tailed).toHaveLength(3);
    expect(tailed.every((row) => !isElided(row.event))).toBe(true);
  });
});
