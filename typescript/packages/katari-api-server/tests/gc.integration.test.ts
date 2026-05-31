// End-to-end single-owner blob GC: run a real agent that produces a `file`
// via `string_to_file`, and assert the blob is freed when the file does NOT
// escape the run, but survives (owned by the run) when it does.

import { randomBytes } from "node:crypto";
import { resetKeyCacheForTesting } from "@katari-lang/runtime";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import {
  buildTestHarness,
  produceFileIR,
  type TestHarness,
  trivialSchemaBundle,
  uploadSnapshot,
} from "./helpers.js";

beforeAll(() => {
  // string_to_file produces a blob; the run result is encrypted into runs_audit,
  // which needs the secret key.
  if (process.env.KATARI_SECRET_KEY === undefined || process.env.KATARI_SECRET_KEY === "") {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

let active: TestHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

async function runMain(harness: TestHarness, projectId: string, snapshotId: string): Promise<string> {
  const start = await harness.app.fetch(
    new Request(`http://test/project/${projectId}/run`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ snapshotId, qualifiedName: "main", args: {} }),
    }),
  );
  expect(start.status).toBe(201);
  const { runId } = (await start.json()) as { runId: string };
  // The actor host drains the bus synchronously, so the run is already terminal.
  const got = await harness.app.fetch(new Request(`http://test/project/${projectId}/run/${runId}`));
  const body = (await got.json()) as { run: { state: string } };
  expect(body.run.state).toBe("succeeded");
  return runId;
}

describe("blob GC: single-owner end-to-end", () => {
  it("a produced file that does NOT escape the run is freed on completion", async () => {
    const harness = buildTestHarness();
    active = harness;
    const { projectId, snapshotId } = await uploadSnapshot(
      harness,
      "gc-drop",
      produceFileIR(false), // returns the string, not the file
      trivialSchemaBundle(),
    );
    await runMain(harness, projectId, snapshotId);
    // The file's blob was owned by the run's shard; it didn't escape in the
    // return value → dropped at the shard's terminal → no blobs left.
    expect(harness.storage.values.blobs.size).toBe(0);
  });

  it("a produced file that the run RETURNS survives, owned by the run", async () => {
    const harness = buildTestHarness();
    active = harness;
    const { projectId, snapshotId } = await uploadSnapshot(
      harness,
      "gc-keep",
      produceFileIR(true), // returns the file
      trivialSchemaBundle(),
    );
    await runMain(harness, projectId, snapshotId);
    // The file escaped in the result → re-owned by the run (runs_audit) → kept.
    expect(harness.storage.values.blobs.size).toBe(1);
  });
});
