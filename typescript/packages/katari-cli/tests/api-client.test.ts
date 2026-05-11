// ApiClient + InMemory api-server harness で end-to-end を確認する。
// Haskell binary は使わない (= compile せずに pre-built IR / SchemaBundle を
// 直接 upload する)。

import { describe, expect, it, afterEach } from "vitest";
import { ApiClient } from "../src/services/api-client.js";
import {
  buildTestHarness,
  literalReturnIR,
  trivialSchemaBundle,
  type TestHarness,
} from "katari-api-server/tests/helpers.js";
import type { Hono } from "hono";

let active: TestHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

/** Build an ApiClient that talks directly to a Hono app via fetch shim. */
function clientFor(app: Hono): ApiClient {
  // Override global fetch so ApiClient's `fetch(url)` calls hit `app.fetch(req)`.
  // Scope: just for this client; restored after each request via try/finally.
  const apiBase = "http://test";
  const shim = (input: Request | URL | string, init?: RequestInit) => {
    const req = input instanceof Request ? input : new Request(input, init);
    return app.fetch(req);
  };
  return new ApiClient({ baseUrl: apiBase }) // baseUrl is irrelevant — fetch is shimmed below
    .withFetch(shim);
}

describe("CLI ApiClient against in-memory api-server", () => {
  it("upserts a project, uploads a snapshot, and starts an agent", async () => {
    const harness = buildTestHarness();
    active = harness;

    const api = clientFor(harness.app);

    const project = await api.upsertProject("smoke");
    expect(project.name).toBe("smoke");

    const { snapshotId } = await api.uploadSnapshot({
      projectId: project.id,
      irModule: literalReturnIR("hello"),
      sidecarBundle: null,
      schemaBundle: trivialSchemaBundle(),
    });
    expect(snapshotId).toMatch(/^[0-9a-f-]{36}$/);

    const { agentId } = await api.startAgent({
      projectId: project.id,
      snapshotId,
      qualifiedName: "main",
      args: {},
    });

    const row = await api.getAgent(agentId);
    expect(row.state).toBe("succeeded");
    // API server returns raw JSON (Value → raw conversion at the
    // boundary), so a string Value lands as just the bare string.
    expect(row.result).toBe("hello");

    const defs = await api.listAgentDefinitions({ projectId: project.id });
    expect(defs.definitions).toHaveLength(1);
    // qualifiedName is now a flat dotted string ("main" or
    // "module.name") — splitting is the caller's responsibility.
    expect(defs.definitions[0]?.qualifiedName).toBe("test.main");
  });
});
