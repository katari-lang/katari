import { Hono } from "hono";
import { cors } from "hono/cors";
import { logger } from "hono/logger";
import { serve } from "@hono/node-server";
import { randomUUID } from "node:crypto";
import type { JsonValue } from "./json.js";
import type {
  SpawnAgentRequest,
  SpawnAgentResponse,
  AgentRequestBody,
  AgentReplyBody,
  AgentReturnBody,
  TerminateBody,
  TerminateAckBody,
  OutgoingMessage,
  RequestInfo,
  AgentDefInfo,
  AgentSummary,
  AgentDetail,
  EffectRef,
} from "./types.js";
import type { KatariProtocol } from "./router.js";
import { buildKatariRouter } from "./router.js";
import { sendOutgoingMessages } from "./client.js";

// ===========================================================================
// AgentContext — passed to each handler
// ===========================================================================

export interface AgentContext {
  agentId: string;
  parentAgentId: string;
  parentAgentWhere: string;
  selfBaseUrl: string;
  /** Send a request to the parent (e.g. on_message, notify) */
  sendRequest(requestDefId: string, args: Record<string, JsonValue>): void;
  /** Spawn a child agent on another server and wait for its return */
  spawnAndWait(
    serverUrl: string,
    agentDefId: string,
    args: Record<string, JsonValue>
  ): Promise<JsonValue>;
}

// ===========================================================================
// Handler type
// ===========================================================================

export type AgentHandlerFn = (
  args: Record<string, JsonValue>,
  ctx: AgentContext
) => Promise<JsonValue>;

// ===========================================================================
// Internal agent state
// ===========================================================================

interface AgentState {
  agentId: string;
  agentDefId: string;
  parentAgentId: string;
  parentAgentWhere: string;
  args: Record<string, JsonValue>;
  withEffects: EffectRef[];
}

// ===========================================================================
// ExternalServer — KatariProtocol impl for external servers
// ===========================================================================

export class ExternalServer implements KatariProtocol {
  private handlers = new Map<string, AgentHandlerFn>();
  private agents = new Map<string, AgentState>();
  private pendingReturns = new Map<
    string,
    { resolve: (v: JsonValue) => void }
  >();
  private selfBaseUrl: string;

  constructor(selfBaseUrl: string) {
    this.selfBaseUrl = selfBaseUrl;
  }

  registerHandler(agentDefId: string, handler: AgentHandlerFn): void {
    this.handlers.set(agentDefId, handler);
  }

  // -- KatariProtocol methods -----------------------------------------------

  listRequests(): RequestInfo[] {
    return [];
  }

  listAgentDefs(): AgentDefInfo[] {
    return Array.from(this.handlers.keys()).map((name) => ({
      agent_def_id: name,
      agent_def_where: this.selfBaseUrl,
      name,
      description: "",
      arg_type: null as JsonValue,
      return_type: null as JsonValue,
      with_effects: [],
    }));
  }

  listAgents(): AgentSummary[] {
    return Array.from(this.agents.values()).map((a) => ({
      agent_id: a.agentId,
      agent_where: this.selfBaseUrl,
      agent_def_id: a.agentDefId,
      args: a.args,
    }));
  }

  getAgent(agentId: string): AgentDetail | null {
    const a = this.agents.get(agentId);
    if (!a) return null;
    return {
      agent_id: a.agentId,
      agent_where: this.selfBaseUrl,
      agent_def_id: a.agentDefId,
      args: a.args,
      parent_agent_id: a.parentAgentId,
      parent_agent_where: a.parentAgentWhere,
      with_effects: [],
      child_agents: [],
    };
  }

  spawnAgent(
    req: SpawnAgentRequest
  ): { response: SpawnAgentResponse; messages: OutgoingMessage[] } | string {
    const handler = this.handlers.get(req.agent_def_id);
    if (!handler) return `unknown agent_def_id: ${req.agent_def_id}`;

    const agentId = `agent-${randomUUID()}`;
    const state: AgentState = {
      agentId,
      agentDefId: req.agent_def_id,
      parentAgentId: req.parent_agent_id,
      parentAgentWhere: req.parent_agent_where,
      args: req.args,
      withEffects: req.with_effects ?? [],
    };
    this.agents.set(agentId, state);

    const ctx = this.makeContext(agentId, req.parent_agent_id, req.parent_agent_where);

    // Run handler asynchronously
    handler(req.args, ctx)
      .then((result) => {
        this.agents.delete(agentId);
        sendOutgoingMessages([
          {
            toUrl: req.parent_agent_where,
            kind: {
              type: "Return",
              body: {
                result,
                from_agent_id: agentId,
                from_agent_where: this.selfBaseUrl,
                agent_id: req.parent_agent_id,
              },
            },
          },
        ]).catch((e) => console.error(`Return send failed:`, e));
      })
      .catch((err) => {
        console.error(`Handler error for ${req.agent_def_id}:`, err);
        this.agents.delete(agentId);
        // Send null result on error
        sendOutgoingMessages([
          {
            toUrl: req.parent_agent_where,
            kind: {
              type: "Return",
              body: {
                result: null,
                from_agent_id: agentId,
                from_agent_where: this.selfBaseUrl,
                agent_id: req.parent_agent_id,
              },
            },
          },
        ]).catch(() => {});
      });

    return {
      response: { agent_id: agentId, agent_where: this.selfBaseUrl },
      messages: [],
    };
  }

  deliverRequest(req: AgentRequestBody): OutgoingMessage[] | string {
    return `external server does not handle incoming requests`;
  }

  deliverReply(req: AgentReplyBody): OutgoingMessage[] | string {
    return `external server does not handle incoming replies`;
  }

  deliverReturn(req: AgentReturnBody): OutgoingMessage[] | string {
    const pending = this.pendingReturns.get(req.from_agent_id);
    if (pending) {
      pending.resolve(req.result);
      this.pendingReturns.delete(req.from_agent_id);
      return [];
    }
    return `no pending return for agent ${req.from_agent_id}`;
  }

  terminateAgent(req: TerminateBody): OutgoingMessage[] | string {
    const agent = this.agents.get(req.agent_id);
    if (!agent) return `agent ${req.agent_id} not found`;
    this.agents.delete(req.agent_id);
    return [
      {
        toUrl: agent.parentAgentWhere,
        kind: {
          type: "TerminateAck",
          body: {
            from_agent_id: req.agent_id,
            from_agent_where: this.selfBaseUrl,
            agent_id: agent.parentAgentId,
          },
        },
      },
    ];
  }

  deliverTerminateAck(req: TerminateAckBody): OutgoingMessage[] | string {
    return [];
  }

  // -- Internal helpers -----------------------------------------------------

  private makeContext(
    agentId: string,
    parentAgentId: string,
    parentAgentWhere: string
  ): AgentContext {
    return {
      agentId,
      parentAgentId,
      parentAgentWhere,
      selfBaseUrl: this.selfBaseUrl,

      sendRequest: (requestDefId: string, args: Record<string, JsonValue>) => {
        sendOutgoingMessages([
          {
            toUrl: parentAgentWhere,
            kind: {
              type: "Request",
              body: {
                request_id: `req-${randomUUID()}`,
                request_def_id: requestDefId,
                request_def_where: this.selfBaseUrl,
                args,
                from_agent_id: agentId,
                from_agent_where: this.selfBaseUrl,
              },
            },
          },
        ]).catch((e) =>
          console.error(`sendRequest(${requestDefId}) failed:`, e)
        );
      },

      spawnAndWait: async (
        serverUrl: string,
        agentDefId: string,
        args: Record<string, JsonValue>
      ): Promise<JsonValue> => {
        const provisionalChildId = `child-${randomUUID()}`;
        const { spawns, failures } = await sendOutgoingMessages([
          {
            toUrl: serverUrl,
            kind: {
              type: "Spawn",
              body: {
                agent_def_id: agentDefId,
                agent_def_where: serverUrl,
                args,
                parent_agent_id: agentId,
                parent_agent_where: this.selfBaseUrl,
              },
              parentAgentId: agentId,
              provisionalChildId,
            },
          },
        ]);

        if (failures.length > 0) {
          throw new Error(failures[0]!.error);
        }
        if (spawns.length === 0) {
          throw new Error(`Spawn failed for ${agentDefId} on ${serverUrl}`);
        }

        const childId = spawns[0]!.actualAgentId;
        return new Promise<JsonValue>((resolve) => {
          this.pendingReturns.set(childId, { resolve });
        });
      },
    };
  }
}

// ===========================================================================
// startServer — one-liner to boot an external server
// ===========================================================================

export function startServer(opts: {
  port: number;
  selfBaseUrl: string;
  handlers: Record<string, AgentHandlerFn>;
}): void {
  const server = new ExternalServer(opts.selfBaseUrl);
  for (const [name, handler] of Object.entries(opts.handlers)) {
    server.registerHandler(name, handler);
  }

  const app = new Hono();
  app.use("*", cors());
  app.use("*", logger());

  const katariRouter = buildKatariRouter(
    () => server,
    (msgs) => {
      if (msgs.length > 0) {
        sendOutgoingMessages(msgs).catch((e) =>
          console.error("outgoing messages failed:", e)
        );
      }
    }
  );
  app.route("/katari", katariRouter);

  app.get("/health", (c) => c.json({ ok: true }));

  console.log(`External server starting on port ${opts.port}`);
  console.log(`Katari protocol at ${opts.selfBaseUrl}`);
  serve({ fetch: app.fetch, port: opts.port });
}
