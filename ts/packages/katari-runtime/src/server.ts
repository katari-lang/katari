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
  kind: "internal" | "external" | "prim";
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

      const externalAgents = resolveExternalAgents(
        body.agents,
        aliasEndpoints,
      );

      // Resolve external agent def UUIDs from external servers
      // (resolveExternalAgents sets agent_def_id to the remote name; replace with actual UUID)
      for (const [, extRef] of externalAgents) {
        const name = extRef.agent_def_id;
        let res: Response;
        try {
          res = await fetch(
            `${extRef.agent_def_where}/agent_definitions?name=${encodeURIComponent(name)}`,
          );
        } catch (e) {
          throw new Error(`Failed to reach external server '${extRef.agent_def_where}' while resolving agent '${name}': ${e}`);
        }
        if (!res.ok) {
          throw new Error(`External server '${extRef.agent_def_where}' returned ${res.status} while resolving agent '${name}'`);
        }
        const defs = (await res.json()) as { id: string; endpoint: string }[];
        if (defs.length === 0) {
          throw new Error(`External agent '${name}' not found at '${extRef.agent_def_where}'. Is the external server running and up to date?`);
        }
        log.log("info", `Resolved external agent '${name}' → ${defs[0]!.id} at ${extRef.agent_def_where}`);
        extRef.agent_def_id = defs[0]!.id;
      }

      // Generate UUID agent_def_ids for each internal agent — completely
      // uncorrelated with compiler block_ids.
      const protocolDefIdToBlockId = new Map<string, number>();
      const primBlockIds = new Map<number, string>();
      for (const entry of body.agents) {
        if (entry.kind === "internal") {
          const agentDefId = crypto.randomUUID();
          // Store bidirectional mapping for this apply session
          protocolDefIdToBlockId.set(agentDefId, entry.block_id);
          // Attach the generated UUID to the entry for later use
          (entry as any)._protocolDefId = agentDefId;
        } else if (entry.kind === "prim") {
          primBlockIds.set(entry.block_id, entry.name);
        }
      }

      const nameToAgentRef = buildNameToAgentRef(
        body.agents,
        externalAgents,
        protocolDefIdToBlockId,
        schemas,
        runtime.getEndpoint(),
      );
      runtime.applyModule(
        module,
        protocolDefIdToBlockId,
        externalAgents,
        aliasEndpoints,
        primBlockIds,
        nameToAgentRef,
      );

      // Drop old runtime-owned protocol resources to avoid stale entries
      await clearRuntimeProtocolResources(protocolStore, runtime.getEndpoint());

      // Generate UUID template_ids for internal requests.
      // External requests get their TemplateRef from the external server.
      const protocolTemplateIdToRequestId = new Map<string, number>();
      const templateEndpoints = new Map<string, string>();
      const requests = body.requests ?? [];

      for (const req of requests) {
        if (req.kind === "internal") {
          const templateId = crypto.randomUUID();
          protocolTemplateIdToRequestId.set(templateId, req.request_id);
          templateEndpoints.set(templateId, runtime.getEndpoint());
          (req as any)._protocolTemplateId = templateId;
        } else if (req.kind === "external" && req.alias) {
          // Resolve external template from the external server
          const colonIdx = req.alias.indexOf(":");
          if (colonIdx > 0) {
            const serverKey = req.alias.slice(0, colonIdx);
            const remoteName = req.alias.slice(colonIdx + 1);
            const serverUrl = aliasEndpoints.get(serverKey);
            if (!serverUrl) {
              throw new Error(`No endpoint configured for server key '${serverKey}' (needed to resolve template '${remoteName}')`);
            }
            let res: Response;
            try {
              res = await fetch(`${serverUrl}/templates?name=${encodeURIComponent(remoteName)}`);
            } catch (e) {
              throw new Error(`Failed to reach external server '${serverUrl}' while resolving template '${remoteName}': ${e}`);
            }
            if (!res.ok) {
              throw new Error(`External server '${serverUrl}' returned ${res.status} while resolving template '${remoteName}'`);
            }
            const templates = (await res.json()) as { id: string; endpoint: string }[];
            if (templates.length === 0) {
              throw new Error(`External template '${remoteName}' not found at '${serverUrl}'. Is the external server running and up to date?`);
            }
            const tmpl = templates[0]!;
            protocolTemplateIdToRequestId.set(tmpl.id, req.request_id);
            templateEndpoints.set(tmpl.id, tmpl.endpoint);
            (req as any)._protocolTemplateId = tmpl.id;
            log.log("info", `Resolved external template '${remoteName}' → ${tmpl.id} at ${tmpl.endpoint}`);
          }
        }
      }

      runtime.setProtocolTemplateMap(protocolTemplateIdToRequestId, templateEndpoints);

      // Register internal templates in protocol store
      for (const req of requests) {
        if (req.kind === "internal") {
          const templateId = (req as any)._protocolTemplateId as string;
          const reqSchema = schemas.get(req.name) as
            | Record<string, JsonValue>
            | undefined;
          await protocolStore.createTemplate({
            id: templateId,
            endpoint: runtime.getEndpoint(),
            name: req.name,
            description: (reqSchema?.description as string) ?? undefined,
            input_schema: reqSchema?.arg_type ?? null,
            output_schema: reqSchema?.return_type ?? null,
          });
        }
      }

      // Build a lookup from request name to TemplateRef (using generated UUIDs)
      const templateRefsByName = new Map<
        string,
        { id: string; endpoint: string }
      >();
      for (const req of requests) {
        if (req.kind === "internal") {
          templateRefsByName.set(req.name, {
            id: (req as any)._protocolTemplateId as string,
            endpoint: runtime.getEndpoint(),
          });
        } else if (req.alias) {
          templateRefsByName.set(req.name, {
            id: String(req.request_id),
            endpoint:
              aliasEndpoints.get(req.alias.split(":")[0] ?? "") ??
              runtime.getEndpoint(),
          });
        }
      }

      // Register agent definitions in protocol store using generated UUIDs
      for (const entry of body.agents) {
        if (entry.kind === "internal") {
          const agentDefId = (entry as any)._protocolDefId as string;
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
            id: agentDefId,
            endpoint: runtime.getEndpoint(),
            name: entry.name,
            description: (schema?.description as string) ?? "",
            input_schema: schema?.arg_type ?? null,
            output_schema: schema?.return_type ?? null,
            template_refs: templateRefs.length > 0 ? templateRefs : undefined,
          });
        }
      }

      // Save to DB (include protocol maps for restore)
      const protocolDefMapObj: Record<string, number> = {};
      for (const [defId, blockId] of protocolDefIdToBlockId) {
        protocolDefMapObj[defId] = blockId;
      }
      const protocolTemplateMapObj: Record<string, { request_id: number; endpoint: string }> = {};
      for (const [templateId, requestId] of protocolTemplateIdToRequestId) {
        protocolTemplateMapObj[templateId] = {
          request_id: requestId,
          endpoint: templateEndpoints.get(templateId) ?? runtime.getEndpoint(),
        };
      }
      // Serialize resolved external agents for restore
      const resolvedExternalAgentsObj: Record<number, { agent_def_id: string; agent_def_where: string }> = {};
      for (const [blockId, extRef] of externalAgents) {
        resolvedExternalAgentsObj[blockId] = extRef;
      }
      await db.saveModule(
        module.name,
        binary,
        body.agents as unknown as Record<string, unknown>,
        body.schemas ?? {},
        body.requests ?? {},
        body.alias_endpoints ?? {},
        protocolDefMapObj,
        protocolTemplateMapObj,
        resolvedExternalAgentsObj,
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

/** Extract external agent refs from metadata */
export function resolveExternalAgents(
  agents: { name: string; block_id: number; kind: string; alias?: string }[],
  aliasEndpoints: Map<string, string>,
): Map<number, { agent_def_id: string; agent_def_where: string }> {
  const externalAgents = new Map<
    number,
    { agent_def_id: string; agent_def_where: string }
  >();
  for (const entry of agents) {
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
  return externalAgents;
}

/** Build name → AgentRef map for ref_agent primitive (internal + external agents) */
export function buildNameToAgentRef(
  agents: { name: string; block_id: number; kind: string }[],
  externalAgents: Map<number, { agent_def_id: string; agent_def_where: string }>,
  protocolDefIdToBlockId: Map<string, number>,
  schemas: Map<string, JsonValue>,
  selfEndpoint: string,
): Map<string, { url: string; agent_def_id: string; name: string; arg_type: JsonValue }> {
  const blockIdToDefId = new Map<number, string>();
  for (const [defId, blockId] of protocolDefIdToBlockId) {
    blockIdToDefId.set(blockId, defId);
  }
  const result = new Map<string, { url: string; agent_def_id: string; name: string; arg_type: JsonValue }>();
  for (const entry of agents) {
    const schema = schemas.get(entry.name) as Record<string, JsonValue> | undefined;
    const argType = schema?.arg_type ?? null;
    if (entry.kind === "external") {
      const extRef = externalAgents.get(entry.block_id);
      if (extRef) {
        result.set(entry.name, {
          url: extRef.agent_def_where,
          agent_def_id: extRef.agent_def_id,
          name: entry.name,
          arg_type: argType,
        });
      }
    } else if (entry.kind === "internal") {
      const defId = blockIdToDefId.get(entry.block_id);
      if (defId) {
        result.set(entry.name, {
          url: selfEndpoint,
          agent_def_id: defId,
          name: entry.name,
          arg_type: argType,
        });
      }
    }
  }
  return result;
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
