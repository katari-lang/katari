// The trace sweep — `DELETE /projects/:projectId/runs/:runId/events`, down through the service to the
// delete it runs. The journal is observation-only (only the events endpoint reads it), so its rows are
// reclaimable at any moment; what must hold is that the sweep is SCOPED to one run and that the journal
// keeps working afterwards. `seq` is a bigserial, so the appends that follow a sweep still climb past
// everything the sweep removed — which is what keeps an open tail's `after=` cursor sound across it.
//
// These run against the real Postgres schema (the scoped delete, the row count it reports, and the
// bigserial's behaviour across a delete are the substrate's own semantics, which no in-memory stub can
// vouch for) and skip when no database is reachable — the suite must stay green on a bare CI runner.

import { randomUUID } from "node:crypto";
import { and, eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { closeDb, db } from "../src/db/client.js";
import { instances, runEvents, runs } from "../src/db/tables/execution.js";
import { projects } from "../src/db/tables/projects.js";
import { NotFoundError } from "../src/lib/errors.js";
import { runEventsRepository } from "../src/modules/run/run-events.repository.js";
import { runService } from "../src/modules/run/run.service.js";
import type { JournalEvent } from "../src/runtime/event/types.js";
import { type InstanceId, newDelegationId, newInstanceId } from "../src/runtime/ids.js";

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

describe.skipIf(!databaseAvailable)("run trace sweep", () => {
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

  /** Journal `count` events under a run, the way a turn's commit appends them. */
  async function appendEvents(runId: InstanceId, count: number): Promise<void> {
    const row = () => {
      const event: JournalEvent = {
        kind: "terminateAck",
        delegation: newDelegationId(),
        from: "core",
        to: "api",
        run: runId,
      };
      return { projectId, runId, event };
    };
    await db.insert(runEvents).values(Array.from({ length: count }, row));
  }

  /** How many journal rows a run currently has, read through the endpoint's own browse query. */
  async function journalSize(runId: InstanceId): Promise<number> {
    const { total } = await runEventsRepository.browse(db, projectId, runId, 0, { limit: 1000 });
    return total;
  }

  /** The seqs a run's journal currently holds, oldest first. */
  async function journalSeqs(runId: InstanceId): Promise<number[]> {
    const { rows } = await runEventsRepository.browse(db, projectId, runId, 0, { limit: 1000 });
    return rows.map((row) => row.seq);
  }

  beforeAll(async () => {
    // A throwaway project row for the FK chain; the afterAll delete cascades everything below it away.
    await db.insert(projects).values({ id: projectId, name: `run-events-clear-test-${projectId}` });
  });

  afterAll(async () => {
    await db.delete(projects).where(eq(projects.id, projectId));
  });

  test("the sweep takes the target run's whole journal and no other run's", async () => {
    const target = await createRun();
    const sibling = await createRun();
    await appendEvents(target, 3);
    await appendEvents(sibling, 2);

    await expect(runEventsRepository.clear(db, projectId, target)).resolves.toBe(3);
    expect(await journalSize(target)).toBe(0);
    // The sibling's trace is untouched — the delete is scoped by (project, run), not by project.
    expect(await journalSize(sibling)).toBe(2);
  });

  test("sweeping an already-empty journal reports nothing swept", async () => {
    const runId = await createRun();
    await expect(runEventsRepository.clear(db, projectId, runId)).resolves.toBe(0);
  });

  test("appends after a sweep keep climbing, so a tail cursor never sees a seq twice", async () => {
    const runId = await createRun();
    await appendEvents(runId, 4);
    const before = await journalSeqs(runId);
    const highestBefore = Math.max(...before);

    await expect(runEventsRepository.clear(db, projectId, runId)).resolves.toBe(4);

    // The journal is live again immediately: this is the resident-run case, where the run goes on
    // producing events after its trace is reclaimed.
    await appendEvents(runId, 2);
    const after = await journalSeqs(runId);
    expect(after).toHaveLength(2);
    for (const seq of after) expect(seq).toBeGreaterThan(highestBefore);
    // And a tail resumed from the last seq the client held before the sweep still sees them.
    const tailed = await runEventsRepository.tail(db, projectId, runId, highestBefore, {
      limit: 1000,
    });
    expect(tailed.map((row) => row.seq)).toEqual(after);
  });

  test("the service refuses a run it cannot find", async () => {
    await expect(runService.clearEvents(projectId, randomUUID())).rejects.toBeInstanceOf(
      NotFoundError,
    );
  });

  test("the service sweeps the run it resolved, leaving the run itself alive", async () => {
    const runId = await createRun();
    await appendEvents(runId, 5);

    await expect(runService.clearEvents(projectId, runId)).resolves.toBe(5);
    expect(await journalSize(runId)).toBe(0);
    // Only the journal went: the run row (and so the run) survives its trace being reclaimed.
    const [row] = await db
      .select({ id: runs.id })
      .from(runs)
      .where(and(eq(runs.projectId, projectId), eq(runs.id, runId)));
    expect(row?.id).toBe(runId);
  });
});
