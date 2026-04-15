import { Hono } from "hono";
import { cors } from "hono/cors";
import {
  KatariServer,
  type KatariStore,
  buildKatariRouter,
  sendOutgoingMessages,
} from "katari-protocol";
import type { OutgoingMessage, JsonValue, KatariLogger } from "katari-protocol";
import { NullKatariLogger } from "katari-protocol";
import type { Value } from "./value.js";
import { Runtime } from "./runtime/index.js";
import { decodeModule } from "./ir.js";
import { Db } from "./db.js";

// ===========================================================================
// Request/Response types
// ===========================================================================

interface AgentMetadataEntry {
  name: string;
  block_id: number;
  kind: "internal" | "external";
  alias?: string; // "server_key:remote_name" for external
}

interface RequestMetadataEntry {
  name: string;
  request_id: number;
  kind: "internal" | "external";
  alias?: string;
}

interface ApplyRequest {
  ir_binary: string; // base64
  agents: AgentMetadataEntry[];
  requests?: RequestMetadataEntry[];
  alias_endpoints?: Record<string, string>;
  schemas?: Record<string, unknown>;
}

interface ApplyResponse {
  ok: boolean;
  error?: string;
  module_name?: string;
  agents?: { id: number; name: string }[];
  requests?: { id: number; name: string }[];
}

// ===========================================================================
// Build server app
// ===========================================================================

export function buildApp(
  runtime: Runtime,
  db: Db,
  protocolStore: KatariStore,
  logger?: KatariLogger,
): Hono {
  const log = logger ?? new NullKatariLogger();
  const app = new Hono();
  app.use("*", cors());

  // Create protocol server with Runtime's hooks
  const katariServer = new KatariServer(
    runtime.getEndpoint(),
    protocolStore,
    runtime.createHooks(),
  );
  runtime.setProtocolServer(katariServer);

  const handleMessages = (msgs: OutgoingMessage[]) => {
    if (msgs.length > 0) {
      sendOutgoingMessages(msgs, log)
        .then(({ failures }) => {
          for (const f of failures) {
            log.log("error", `Outgoing message failed: ${f.error}`);
          }
        })
        .catch((e) => {
          log.log("error", `sendOutgoingMessages failed: ${e}`);
        });
    }
  };

  // ==========================================================================
  // POST /apply
  // ==========================================================================

  app.post("/apply", async (c) => {
    const body = (await c.req.json()) as ApplyRequest;

    try {
      const binary = base64ToUint8Array(body.ir_binary);
      const module = decodeModule(binary);

      const aliasEndpoints = new Map(
        Object.entries(body.alias_endpoints ?? {}),
      );
      const schemas = new Map(Object.entries(body.schemas ?? {})) as Map<
        string,
        JsonValue
      >;

      const { nameMap, externalAgents } = resolveMetadata(
        body.agents,
        aliasEndpoints,
      );

      runtime.applyModule(
        module,
        nameMap,
        schemas,
        externalAgents,
        aliasEndpoints,
      );

      // Drop old runtime-owned protocol resources to avoid stale entries
      await clearRuntimeProtocolResources(protocolStore, runtime.getEndpoint());

      // Register templates (requests) in protocol store
      const requests = body.requests ?? [];
      for (const req of requests) {
        if (req.kind === "internal") {
          const reqSchema = schemas.get(req.name) as
            | Record<string, JsonValue>
            | undefined;
          await protocolStore.createTemplate({
            id: String(req.request_id),
            endpoint: runtime.getEndpoint(),
            name: req.name,
            description: (reqSchema?.description as string) ?? undefined,
            input_schema: reqSchema?.arg_type ?? null,
            output_schema: reqSchema?.return_type ?? null,
          });
        }
      }

      // Build a lookup from request name to TemplateRef
      const templateRefsByName = new Map<
        string,
        { id: string; endpoint: string }
      >();
      for (const req of requests) {
        templateRefsByName.set(req.name, {
          id: String(req.request_id),
          endpoint:
            req.kind === "internal"
              ? runtime.getEndpoint()
              : (aliasEndpoints.get(req.alias?.split(":")[0] ?? "") ??
                runtime.getEndpoint()),
        });
      }

      // Register agent definitions in protocol store
      for (const entry of body.agents) {
        if (entry.kind === "internal") {
          const schema = schemas.get(entry.name) as
            | Record<string, JsonValue>
            | undefined;
          const withEffects =
            (schema?.with_effects as string[] | undefined) ?? [];
          const templateRefs = withEffects
            .map((name) => templateRefsByName.get(name))
            .filter(
              (ref): ref is { id: string; endpoint: string } => ref != null,
            );
          await protocolStore.createAgentDefinition({
            id: String(entry.block_id),
            endpoint: runtime.getEndpoint(),
            name: entry.name,
            description: (schema?.description as string) ?? "",
            input_schema: schema?.arg_type ?? null,
            output_schema: schema?.return_type ?? null,
            template_refs: templateRefs.length > 0 ? templateRefs : undefined,
          });
        }
      }

      // Save to DB
      await db.saveModule(
        module.name,
        binary,
        body.agents as unknown as Record<string, unknown>,
        body.schemas ?? {},
        body.requests ?? {},
        body.alias_endpoints ?? {},
      );

      const response: ApplyResponse = {
        ok: true,
        module_name: module.name,
        agents: runtime.getModuleAgents(),
        requests: runtime.getModuleRequests(),
      };
      return c.json(response);
    } catch (e) {
      return c.json(
        { ok: false, error: String(e) } satisfies ApplyResponse,
        400,
      );
    }
  });

  // ==========================================================================
  // /agents — toplevel agent management
  // ==========================================================================

  const agentsRouter = new Hono();

  // GET /agents
  agentsRouter.get("/", async (c) => {
    const rows = await db.listToplevelAgents();
    return c.json({ agents: rows });
  });

  // POST /agents
  agentsRouter.post("/", async (c) => {
    const body = (await c.req.json()) as {
      agent_name: string;
      args?: Record<string, JsonValue>;
    };

    try {
      const agentId = await runtime.runAgent(
        body.agent_name,
        (body.args ?? {}) as Record<string, Value>,
      );

      const msgs = runtime.drainMessages();
      handleMessages(msgs);

      const status = runtime.getAgentStatus(agentId);
      return c.json({
        ok: true,
        agent_id: agentId,
        status: status?.status ?? "running",
        result: (status?.result as JsonValue) ?? null,
      });
    } catch (e) {
      return c.json({ ok: false, error: String(e) }, 400);
    }
  });

  // GET /agents/:id
  // @ts-expect-error Hono deep type instantiation with /:id + /:id/stop
  agentsRouter.get("/:id", async (c) => {
    const id = c.req.param("id") as string;

    const memStatus = runtime.getAgentStatus(id);
    if (memStatus) {
      return c.json({
        id,
        status: memStatus.status,
        result: (memStatus.result as JsonValue) ?? null,
      });
    }

    const row = await db.loadAgent(id);
    if (!row) return c.json({ error: "not found" }, 404);
    return c.json({
      id: row.id,
      status: row.status,
      result: row.result,
    });
  });

  // POST /agents/:id/stop
  agentsRouter.post("/:id/stop", async (c) => {
    const id = c.req.param("id");

    if (runtime.hasAgent(id)) {
      await runtime.stopAgent(id);
      const msgs = runtime.drainMessages();
      handleMessages(msgs);
      return c.json({ ok: true });
    }

    const row = await db.loadAgent(id);
    if (!row) return c.json({ error: "agent not found" }, 404);

    if (row.status === "running") {
      await db.updateAgentStatus(id, "stopped", null);
      return c.json({
        ok: true,
        note: "agent was stale (not in runtime memory)",
      });
    }

    return c.json({ error: `agent already ${row.status}` }, 400);
  });

  app.route("/agents", agentsRouter);

  // ==========================================================================
  // Katari Protocol routes
  // ==========================================================================

  const katariRouter = buildKatariRouter(
    () => katariServer,
    (msgs) => {
      const runtimeMsgs = runtime.drainMessages();
      handleMessages([...msgs, ...runtimeMsgs]);
    },
    log,
  );

  app.route("/katari", katariRouter);

  // ==========================================================================
  // Health check
  // ==========================================================================

  app.get("/health", (c) => c.json({ ok: true }));

  return app;
}

async function clearRuntimeProtocolResources(
  store: KatariStore,
  endpoint: string,
): Promise<void> {
  const [defs, templates] = await Promise.all([
    store.listAgentDefinitions(),
    store.listTemplates(),
  ]);

  await Promise.all([
    ...defs
      .filter((d) => d.endpoint === endpoint)
      .map((d) => store.deleteAgentDefinition(d.id)),
    ...templates
      .filter((t) => t.endpoint === endpoint)
      .map((t) => store.deleteTemplate(t.id)),
  ]);
}

/** Convert new metadata format to the maps the runtime expects */
export function resolveMetadata(
  agents: { name: string; block_id: number; kind: string; alias?: string }[],
  aliasEndpoints: Map<string, string>,
): {
  nameMap: Map<string, number>;
  externalAgents: Map<
    number,
    { agent_def_id: string; agent_def_where: string }
  >;
} {
  const nameMap = new Map<string, number>();
  const externalAgents = new Map<
    number,
    { agent_def_id: string; agent_def_where: string }
  >();
  for (const entry of agents) {
    nameMap.set(entry.name, entry.block_id);
    if (entry.kind === "external" && entry.alias) {
      const colonIdx = entry.alias.indexOf(":");
      if (colonIdx > 0) {
        const serverKey = entry.alias.slice(0, colonIdx);
        const remoteName = entry.alias.slice(colonIdx + 1);
        const serverUrl = aliasEndpoints.get(serverKey);
        if (serverUrl) {
          externalAgents.set(entry.block_id, {
            agent_def_id: remoteName,
            agent_def_where: serverUrl,
          });
        }
      }
    }
  }
  return { nameMap, externalAgents };
}

function base64ToUint8Array(b64: string): Uint8Array {
  if (typeof Buffer !== "undefined") {
    return Buffer.from(b64, "base64");
  }
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
