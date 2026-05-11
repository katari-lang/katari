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
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId,
          snapshotId,
          qualifiedName: "main",
          args: {},
        }),
      }),
    );
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await harness.app.fetch(
      new Request(`http://test/agent/${agentId}`),
    );
    expect(got.status).toBe(200);
    const body = (await got.json()) as {
      agent: { state: string; result: string };
    };
    expect(body.agent.state).toBe("succeeded");
    // Wire format: raw JSON values (the API server converts Value→raw at
    // the boundary), so a string Value lands as just the string.
    expect(body.agent.result).toBe("hello");
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
      new Request("http://test/agent", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          projectId,
          qualifiedName: "main",
          args: {},
        }),
      }),
    );
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await harness.app.fetch(
      new Request(`http://test/agent/${agentId}`),
    );
    const body = (await got.json()) as {
      agent: { state: string; result: string };
    };
    expect(body.agent.state).toBe("succeeded");
    expect(body.agent.result).toBe("second");
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
      new Request("http://test/agent/00000000-0000-0000-0000-000000000000"),
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
