import { Hono } from "hono";
import type {
  RequestInfo,
  AgentDefInfo,
  AgentSummary,
  AgentDetail,
  SpawnAgentRequest,
  SpawnAgentResponse,
  AgentRequestBody,
  AgentReplyBody,
  AgentReturnBody,
  TerminateBody,
  TerminateAckBody,
  OutgoingMessage,
  SuccessResponse,
  ErrorResponse,
} from "./types.js";

// ===========================================================================
// KatariProtocol interface
// ===========================================================================

export interface KatariProtocol {
  listRequests(moduleName?: string): RequestInfo[];
  listAgentDefs(moduleName?: string): AgentDefInfo[];
  listAgents(): AgentSummary[];
  getAgent(agentId: string): AgentDetail | null;
  spawnAgent(
    req: SpawnAgentRequest
  ): { response: SpawnAgentResponse; messages: OutgoingMessage[] } | string;
  deliverRequest(req: AgentRequestBody): OutgoingMessage[] | string;
  deliverReply(req: AgentReplyBody): OutgoingMessage[] | string;
  deliverReturn(req: AgentReturnBody): OutgoingMessage[] | string;
  terminateAgent(req: TerminateBody): OutgoingMessage[] | string;
  deliverTerminateAck(req: TerminateAckBody): OutgoingMessage[] | string;
}

// ===========================================================================
// Hono router builder
// ===========================================================================

export function buildKatariRouter(
  getProtocol: () => KatariProtocol,
  afterMessages: (msgs: OutgoingMessage[]) => void
): Hono {
  const app = new Hono();

  // GET /request
  app.get("/request", (c) => {
    const moduleName = c.req.query("module_name");
    return c.json(getProtocol().listRequests(moduleName));
  });

  // GET /agent_def
  app.get("/agent_def", (c) => {
    const moduleName = c.req.query("module_name");
    return c.json(getProtocol().listAgentDefs(moduleName));
  });

  // GET /agent
  app.get("/agent", (c) => {
    return c.json(getProtocol().listAgents());
  });

  // GET /agent/:id
  app.get("/agent/:id", (c) => {
    const detail = getProtocol().getAgent(c.req.param("id"));
    if (!detail) return c.json({ error: "agent not found" } satisfies ErrorResponse, 404);
    return c.json(detail);
  });

  // POST /agent (spawn)
  app.post("/agent", async (c) => {
    const body = (await c.req.json()) as SpawnAgentRequest;
    console.log(`[katari] spawn agent_def_id=${body.agent_def_id} parent=${body.parent_agent_id}`);
    const result = getProtocol().spawnAgent(body);
    if (typeof result === "string") {
      console.error(`[katari] spawn error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json(result.response);
  });

  // POST /agent/request
  app.post("/agent/request", async (c) => {
    const body = (await c.req.json()) as AgentRequestBody;
    console.log(`[katari] request def_id=${body.request_def_id} from=${body.from_agent_id}`);
    const result = getProtocol().deliverRequest(body);
    if (typeof result === "string") {
      console.error(`[katari] request error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/reply
  app.post("/agent/reply", async (c) => {
    const body = (await c.req.json()) as AgentReplyBody;
    console.log(`[katari] reply request_id=${body.request_id} agent=${body.agent_id}`);
    const result = getProtocol().deliverReply(body);
    if (typeof result === "string") {
      console.error(`[katari] reply error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/return
  app.post("/agent/return", async (c) => {
    const body = (await c.req.json()) as AgentReturnBody;
    console.log(`[katari] return from=${body.from_agent_id} to=${body.agent_id}`);
    const result = getProtocol().deliverReturn(body);
    if (typeof result === "string") {
      console.error(`[katari] return error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/terminate
  app.post("/agent/terminate", async (c) => {
    const body = (await c.req.json()) as TerminateBody;
    console.log(`[katari] terminate agent=${body.agent_id} from=${body.from_agent_id}`);
    const result = getProtocol().terminateAgent(body);
    if (typeof result === "string") {
      console.error(`[katari] terminate error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/terminate_ack
  app.post("/agent/terminate_ack", async (c) => {
    const body = (await c.req.json()) as TerminateAckBody;
    console.log(`[katari] terminate_ack from=${body.from_agent_id} to=${body.agent_id}`);
    const result = getProtocol().deliverTerminateAck(body);
    if (typeof result === "string") {
      console.error(`[katari] terminate_ack error: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  return app;
}
