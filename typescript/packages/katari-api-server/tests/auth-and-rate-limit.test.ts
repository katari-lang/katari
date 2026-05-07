// Middleware behavior: auth + rate limit. Pure middleware tests, kept
// separate from end-to-end so we can flip the test rig configuration
// without polluting the happy-path coverage.

import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  AgentService,
  buildApp,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";

function setup(opts: {
  apiKey?: string | null;
  rateLimit?: Parameters<typeof buildApp>[0]["rateLimit"];
}) {
  const storage = new InMemoryStorage();
  const logger = noopLogger;
  const registry = new MachineRegistry(storage, logger);
  const modules = new ModuleService(storage, logger);
  const agents = new AgentService(storage, registry, logger);
  const app = buildApp({
    agents,
    modules,
    apiKey: opts.apiKey,
    rateLimit: opts.rateLimit,
  });
  return { app };
}

describe("auth middleware", () => {
  it("rejects requests without an Authorization header (401)", async () => {
    const { app } = setup({ apiKey: "secret-key", rateLimit: null });
    const r = await app.fetch(new Request("http://test/agent"));
    expect(r.status).toBe(401);
  });

  it("rejects requests with a wrong API key (401)", async () => {
    const { app } = setup({ apiKey: "secret-key", rateLimit: null });
    const r = await app.fetch(
      new Request("http://test/agent", {
        headers: { Authorization: "Bearer wrong" },
      }),
    );
    expect(r.status).toBe(401);
  });

  it("accepts requests with the correct Bearer token", async () => {
    const { app } = setup({ apiKey: "secret-key", rateLimit: null });
    const r = await app.fetch(
      new Request("http://test/agent", {
        headers: { Authorization: "Bearer secret-key" },
      }),
    );
    expect(r.status).toBe(200);
  });

  it("/healthz bypasses auth", async () => {
    const { app } = setup({ apiKey: "secret-key", rateLimit: null });
    const r = await app.fetch(new Request("http://test/healthz"));
    expect(r.status).toBe(200);
    expect(await r.text()).toBe("ok");
  });

  it("server returns 503 when KATARI_API_KEY is unset (apiKey === undefined)", async () => {
    const { app } = setup({ apiKey: undefined, rateLimit: null });
    const r = await app.fetch(new Request("http://test/agent"));
    expect(r.status).toBe(503);
  });
});

describe("rate limit middleware", () => {
  it("rejects bursts beyond capacity with 429", async () => {
    const { app } = setup({
      apiKey: null,
      rateLimit: { capacity: 3, refillPerSecond: 0.001 },
    });
    // Three requests succeed (depleting tokens 3 → 0).
    for (let i = 0; i < 3; i++) {
      const r = await app.fetch(new Request("http://test/agent"));
      expect(r.status).toBe(200);
    }
    // Fourth is throttled.
    const blocked = await app.fetch(new Request("http://test/agent"));
    expect(blocked.status).toBe(429);
    expect(blocked.headers.get("Retry-After")).not.toBeNull();
  });

  it("/healthz bypasses rate limit", async () => {
    const { app } = setup({
      apiKey: null,
      rateLimit: { capacity: 1, refillPerSecond: 0.001 },
    });
    // Burn the one token elsewhere.
    await app.fetch(new Request("http://test/agent"));
    // /healthz still works.
    const r = await app.fetch(new Request("http://test/healthz"));
    expect(r.status).toBe(200);
  });
});

describe("validation", () => {
  it("malformed JSON in POST body returns 400", async () => {
    const { app } = setup({ apiKey: null, rateLimit: null });
    const r = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{not json",
      }),
    );
    expect(r.status).toBe(400);
  });

  it("invalid UUID in versionId path returns 400", async () => {
    const { app } = setup({ apiKey: null, rateLimit: null });
    const r = await app.fetch(new Request("http://test/module/not-a-uuid"));
    expect(r.status).toBe(400);
  });

  it("oversized request body (Content-Length > 10MB) returns 413", async () => {
    const { app } = setup({ apiKey: null, rateLimit: null });
    const r = await app.fetch(
      new Request("http://test/module", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "content-length": String(11 * 1024 * 1024),
        },
        body: "{}",
      }),
    );
    expect(r.status).toBe(413);
  });
});
