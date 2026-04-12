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
    const result = getProtocol().spawnAgent(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json(result.response);
  });

  // POST /agent/request
  app.post("/agent/request", async (c) => {
    const body = (await c.req.json()) as AgentRequestBody;
    const result = getProtocol().deliverRequest(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/reply
  app.post("/agent/reply", async (c) => {
    const body = (await c.req.json()) as AgentReplyBody;
    const result = getProtocol().deliverReply(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/return
  app.post("/agent/return", async (c) => {
    const body = (await c.req.json()) as AgentReturnBody;
    const result = getProtocol().deliverReturn(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/terminate
  app.post("/agent/terminate", async (c) => {
    const body = (await c.req.json()) as TerminateBody;
    const result = getProtocol().terminateAgent(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /agent/terminate_ack
  app.post("/agent/terminate_ack", async (c) => {
    const body = (await c.req.json()) as TerminateAckBody;
    const result = getProtocol().deliverTerminateAck(body);
    if (typeof result === "string") {
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  return app;
}
