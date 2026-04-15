import { Hono } from "hono";
import type { KatariServer } from "./server.js";
import type {
  DelegateRequest,
  DelegateAckRequest,
  EscalateRequest,
  EscalateAckRequest,
  TerminateRequest,
  TerminateAckRequest,
  ThrowRequest,
  ErrorResponse,
  SuccessResponse,
  OutgoingMessage,
} from "./types.js";
import type { KatariLogger } from "./logger.js";
import { NullKatariLogger } from "./logger.js";

// ===========================================================================
// Hono router builder for Katari Protocol endpoints
// ===========================================================================

export function buildKatariRouter(
  getServer: () => KatariServer,
  afterMessages: (msgs: OutgoingMessage[]) => void,
  logger?: KatariLogger
): Hono {
  const log = logger ?? new NullKatariLogger();
  const app = new Hono();

  // =========================================================================
  // POST endpoints
  // =========================================================================

  // POST /delegate
  app.post("/delegate", async (c) => {
    const body = (await c.req.json()) as DelegateRequest;
    log.protocolRecv("delegate", body.delegation_ref?.endpoint ?? null, {
      agent_def: body.agent_def_ref.id,
      delegation: body.delegation_ref?.id,
    });
    const result = await getServer().handleDelegate(body);
    if (typeof result === "string") {
      log.log("warn", `delegate rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json(result.response);
  });

  // POST /delegate_ack
  app.post("/delegate_ack", async (c) => {
    const body = (await c.req.json()) as DelegateAckRequest;
    log.protocolRecv("delegate_ack", body.delegation_ref.endpoint, {
      delegation: body.delegation_ref.id,
    });
    const result = await getServer().handleDelegateAck(body);
    if (typeof result === "string") {
      log.log("warn", `delegate_ack rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /escalate
  app.post("/escalate", async (c) => {
    const body = (await c.req.json()) as EscalateRequest;
    log.protocolRecv("escalate", body.escalation_ref.endpoint, {
      capability: body.capability_ref.id,
      escalation: body.escalation_ref.id,
    });
    const result = await getServer().handleEscalate(body);
    if (typeof result === "string") {
      log.log("warn", `escalate rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /escalate_ack
  app.post("/escalate_ack", async (c) => {
    const body = (await c.req.json()) as EscalateAckRequest;
    log.protocolRecv("escalate_ack", body.escalation_ref.endpoint, {
      escalation: body.escalation_ref.id,
    });
    const result = await getServer().handleEscalateAck(body);
    if (typeof result === "string") {
      log.log("warn", `escalate_ack rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /terminate
  app.post("/terminate", async (c) => {
    const body = (await c.req.json()) as TerminateRequest;
    log.protocolRecv("terminate", body.delegation_ref.endpoint, {
      delegation: body.delegation_ref.id,
    });
    const result = await getServer().handleTerminate(body);
    if (typeof result === "string") {
      log.log("warn", `terminate rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /terminate_ack
  app.post("/terminate_ack", async (c) => {
    const body = (await c.req.json()) as TerminateAckRequest;
    log.protocolRecv("terminate_ack", body.delegation_ref.endpoint, {
      delegation: body.delegation_ref.id,
    });
    const result = await getServer().handleTerminateAck(body);
    if (typeof result === "string") {
      log.log("warn", `terminate_ack rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // POST /throw
  app.post("/throw", async (c) => {
    const body = (await c.req.json()) as ThrowRequest;
    log.protocolRecv("throw", body.delegation_ref.endpoint, {
      delegation: body.delegation_ref.id,
      message: body.message,
    });
    const result = await getServer().handleThrow(body);
    if (typeof result === "string") {
      log.log("warn", `throw rejected: ${result}`);
      return c.json({ error: result } satisfies ErrorResponse, 400);
    }
    afterMessages(result.messages);
    return c.json({ success: true } satisfies SuccessResponse);
  });

  // =========================================================================
  // GET endpoints — resource queries
  // =========================================================================

  app.get("/agent_definitions", async (c) => {
    const defs = await getServer().listAgentDefinitions();
    return c.json(defs);
  });

  app.get("/agents", async (c) => {
    const agents = await getServer().listAgents();
    return c.json(agents);
  });

  app.get("/delegations", async (c) => {
    const delegations = await getServer().listDelegations();
    return c.json(delegations);
  });

  app.get("/templates", async (c) => {
    const templates = await getServer().listTemplates();
    return c.json(templates);
  });

  app.get("/capabilities", async (c) => {
    const capabilities = await getServer().listCapabilities();
    return c.json(capabilities);
  });

  app.get("/escalations", async (c) => {
    const escalations = await getServer().listEscalations();
    return c.json(escalations);
  });

  return app;
}
