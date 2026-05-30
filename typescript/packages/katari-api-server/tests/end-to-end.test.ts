// Smoke test for the new project / snapshot / agent flow.

import { describe, expect, it, afterEach } from "vitest";
import {
  buildTestHarness,
  literalReturnIR,
  trivialSchemaBundle,
  uploadSnapshot,
  type TestHarness,
} from "./helpers.js";

let active: TestHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

describe("end-to-end: project + snapshot + agent flow", () => {
  it("upload snapshot → start agent (sync) → succeeded with result", async () => {
    const harness = buildTestHarness();
    active = harness;

    const { projectId, snapshotId } = await uploadSnapshot(
      harness,
      "demo-project",
      literalReturnIR("hello"),
      trivialSchemaBundle(),
    );
    expect(snapshotId).toMatch(/^[0-9a-f-]{36}$/);

    const start = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/run`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          snapshotId,
          qualifiedName: "main",
          args: {},
        }),
      }),
    );
    expect(start.status).toBe(201);
    const { runId } = (await start.json()) as { runId: string };

    const got = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/run/${runId}`),
    );
    expect(got.status).toBe(200);
    const body = (await got.json()) as {
      run: { state: string; result: string };
    };
    expect(body.run.state).toBe("succeeded");
    // Wire format: raw JSON values (the API server converts Value→raw at
    // the boundary), so a string Value lands as just the string.
    expect(body.run.result).toBe("hello");
  });

  it("snapshotId omitted → uses latest of the project", async () => {
    const harness = buildTestHarness();
    active = harness;

    const { projectId } = await uploadSnapshot(
      harness,
      "latest-test",
      literalReturnIR("first"),
      trivialSchemaBundle(),
    );
    // upload a second snapshot — should become the latest
    await uploadSnapshot(
      harness,
      "latest-test",
      literalReturnIR("second"),
      trivialSchemaBundle(),
    );

    const start = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/run`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          qualifiedName: "main",
          args: {},
        }),
      }),
    );
    const { runId } = (await start.json()) as { runId: string };

    const got = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/run/${runId}`),
    );
    const body = (await got.json()) as {
      run: { state: string; result: string };
    };
    expect(body.run.state).toBe("succeeded");
    expect(body.run.result).toBe("second");
  });

  it("unhandled throw (missing entry) → run reaches error, not stuck running", async () => {
    const harness = buildTestHarness();
    active = harness;
    const { projectId, snapshotId } = await uploadSnapshot(
      harness,
      "throw-proj",
      literalReturnIR("x"),
      trivialSchemaBundle(),
    );

    // Start a run for an agent that doesn't exist in `entries`. CORE raises
    // EntryNotFoundError → a `primitive.throw` escalate → ApiModule must DETECT
    // it (the bug: it matched `prim.throw` and recorded an open escalation, so
    // the run stayed `running` forever) → run cancels with reason=error.
    const start = await harness.app.fetch(
      new Request(`http://test/project/${projectId}/run`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ snapshotId, qualifiedName: "does_not_exist", args: {} }),
      }),
    );
    expect(start.status).toBe(201);
    const { runId } = (await start.json()) as { runId: string };

    let state = "running";
    for (let i = 0; i < 50 && (state === "running" || state === "cancelling"); i++) {
      await new Promise((r) => setTimeout(r, 10));
      const got = await harness.app.fetch(
        new Request(`http://test/project/${projectId}/run/${runId}`),
      );
      state = ((await got.json()) as { run: { state: string } }).run.state;
    }
    expect(state).toBe("error");
  });

  it("rejects POST /project/:p/snapshot without irModule", async () => {
    const harness = buildTestHarness();
    active = harness;
    const project = await harness.app.fetch(
      new Request("http://test/project", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "rejects-test" }),
      }),
    );
    const { project: p } = (await project.json()) as { project: { id: string } };
    const r = await harness.app.fetch(
      new Request(`http://test/project/${p.id}/snapshot`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ schemaBundle: trivialSchemaBundle() }),
      }),
    );
    expect(r.status).toBe(400);
  });

  it("returns 404 for unknown agent / snapshot", async () => {
    const harness = buildTestHarness();
    active = harness;
    const a = await harness.app.fetch(
      new Request(
        "http://test/project/00000000-0000-0000-0000-000000000000/run/00000000-0000-0000-0000-000000000000",
      ),
    );
    expect(a.status).toBe(404);
    const s = await harness.app.fetch(
      new Request(
        "http://test/project/00000000-0000-0000-0000-000000000000/snapshot/00000000-0000-0000-0000-000000000000",
      ),
    );
    expect(s.status).toBe(404);
  });
});
