import { describe, expect, it } from "vitest";
import { noopLogger } from "katari-runtime";
import {
  buildApp,
  AgentService,
  InMemoryStorage,
  MachineRegistry,
  ModuleService,
} from "../src/index.js";
import { literalReturnIR, trivialSchemaBundle } from "./helpers.js";

function setup() {
  const storage = new InMemoryStorage();
  const logger = noopLogger;
  const registry = new MachineRegistry(storage, logger);
  const modules = new ModuleService(storage, logger);
  const agents = new AgentService(storage, registry, logger);
  // apiKey: null disables auth, rateLimit: null disables throttling — these
  // tests focus on the routes/services surface, not on middleware. A dedicated
  // middleware test exercises auth and rate-limit independently.
  const app = buildApp({ modules, agents, apiKey: null, rateLimit: null });
  return { app, storage, registry, modules, agents };
}

async function postJson(
  app: ReturnType<typeof buildApp>,
  path: string,
  body: unknown,
): Promise<Response> {
  return app.fetch(
    new Request(`http://test${path}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  );
}

async function getJson(
  app: ReturnType<typeof buildApp>,
  path: string,
): Promise<Response> {
  return app.fetch(new Request(`http://test${path}`));
}

describe("end-to-end: module + agent flow", () => {
  it("upload module → start agent (sync) → succeeded with result", async () => {
    const { app } = setup();

    const upload = await postJson(app, "/module", {
      irModule: literalReturnIR("hello"),
      schemaBundle: trivialSchemaBundle(),
    });
    expect(upload.status).toBe(201);
    const { versionId } = (await upload.json()) as { versionId: string };
    expect(versionId).toMatch(/^[0-9a-f-]{36}$/);

    const start = await postJson(app, "/agent", {
      versionId,
      qualifiedName: "main",
      args: {},
    });
    expect(start.status).toBe(201);
    const { agentId } = (await start.json()) as { agentId: string };

    const got = await getJson(app, `/agent/${agentId}`);
    expect(got.status).toBe(200);
    const row = (await got.json()) as {
      state: string;
      result: { kind: string; value: string };
    };
    expect(row.state).toBe("succeeded");
    expect(row.result).toEqual({ kind: "string", value: "hello" });
  });

  it("agent-definition list and single", async () => {
    const { app } = setup();
    const upload = await postJson(app, "/module", {
      irModule: literalReturnIR("hi"),
      schemaBundle: trivialSchemaBundle(),
    });
    const { versionId } = (await upload.json()) as { versionId: string };

    const all = await getJson(app, `/agent-definition?versionId=${versionId}`);
    expect(all.status).toBe(200);
    const allBody = (await all.json()) as {
      agents: { qualifiedName: { module_: string; name: string } }[];
    };
    expect(allBody.agents).toHaveLength(1);
    expect(allBody.agents[0]?.qualifiedName).toEqual({
      module_: "test",
      name: "main",
    });

    const single = await getJson(
      app,
      `/agent-definition/${versionId}/${encodeURIComponent("test.main")}`,
    );
    expect(single.status).toBe(200);
    const singleBody = (await single.json()) as {
      qualifiedName: { module_: string; name: string };
      description?: string;
    };
    expect(singleBody.qualifiedName).toEqual({ module_: "test", name: "main" });
    expect(singleBody.description).toBe("Returns a greeting");
  });

  it("rejects POST /module without schemaBundle", async () => {
    const { app } = setup();
    const r = await postJson(app, "/module", {
      irModule: literalReturnIR("x"),
    });
    expect(r.status).toBe(400);
  });

  it("returns 404 for unknown agent / module", async () => {
    const { app } = setup();
    const a = await getJson(app, "/agent/00000000-0000-0000-0000-000000000000");
    expect(a.status).toBe(404);
    const m = await getJson(app, "/module/00000000-0000-0000-0000-000000000000");
    expect(m.status).toBe(404);
  });
});
