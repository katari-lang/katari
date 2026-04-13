import { v4 as uuidv4 } from "uuid";
import type { OutgoingMessage, JsonValue } from "katari-protocol";
import type { AgentState, Event, PendingRequest } from "./types.js";
import { getVar, setVar, routeRequestToHandle } from "./types.js";
import type { Value } from "../value.js";
import { callPrimitive } from "../primitive.js";

// ===========================================================================
// Config for external routing
// ===========================================================================

export interface ExternalAgentRef {
  agent_def_id: string;
  agent_def_where: string;
}

export interface RequestConfig {
  selfBaseUrl: string;
  externalAgents: Map<number, ExternalAgentRef>;
}

// ===========================================================================
// ICall — agent invocation
// ===========================================================================

export function handleICall(
  agent: AgentState,
  threadId: number,
  dst: number,
  agentDefId: number,
  argVars: number[],
  events: Event[],
  messages: OutgoingMessage[],
  config: RequestConfig
): void {
  const agentDef = agent.module.agents.find((a) => a.id === agentDefId);

  // Primitive agents (synchronous)
  if (agentDef?.name.startsWith("prim.")) {
    const argValues = argVars.map((v) => getVar(agent, v));
    const result = callPrimitive(agentDef.name, argValues);
    if (result.tag === "Ok") {
      setVar(agent, dst, result.value);
      return;
    }
    if (result.tag === "RaiseRequest") {
      const rid = agent.module.requests.find((r) => r.name === result.reqName)?.id;
      if (rid !== undefined) {
        const requestId = uuidv4();
        const t = agent.threads.get(threadId)!;
        t.status = { tag: "Suspended", reason: { tag: "Request", requestId, dst } };
        const pending: PendingRequest = {
          requestId,
          reqDefId: rid,
          args: result.args,
          fromAgentId: agent.agentId,
          fromAgentWhere: "",
        };
        const route = routeRequestToHandle(agent, threadId, rid);
        if (route) {
          events.push({
            agentId: agent.agentId,
            kind: {
              tag: "IncomingRequest",
              ownerThreadId: route[0],
              request: pending,
              handlerDefTid: route[1],
            },
          });
        }
      }
      return;
    }
  }

  // External agent?
  const externalRef = config.externalAgents.get(agentDefId);
  if (externalRef) {
    const argValues = argVars.map((v) => getVar(agent, v));
    const childAgentId = `agent-${uuidv4()}`;
    const t = agent.threads.get(threadId)!;
    t.status = { tag: "Suspended", reason: { tag: "Call", childAgentId, dst } };
    agent.children.set(childAgentId, threadId);

    messages.push({
      toUrl: externalRef.agent_def_where,
      kind: {
        type: "Spawn",
        body: {
          agent_def_id: externalRef.agent_def_id,
          agent_def_where: externalRef.agent_def_where,
          args: argValues as JsonValue[],
          parent_agent_id: agent.agentId,
          parent_agent_where: config.selfBaseUrl,
        },
        parentAgentId: agent.agentId,
        provisionalChildId: childAgentId,
      },
    });
    return;
  }

  // Local non-primitive agent
  const argValues = argVars.map((v) => getVar(agent, v));
  const childAgentId = `agent-${uuidv4()}`;
  const t = agent.threads.get(threadId)!;
  t.status = { tag: "Suspended", reason: { tag: "Call", childAgentId, dst } };
  agent.children.set(childAgentId, threadId);
  events.push({
    agentId: agent.agentId,
    kind: {
      tag: "SpawnChildAgent",
      childAgentId,
      agentDefId,
      args: argValues,
    },
  });
}

// ===========================================================================
// IRequest — request invocation
// ===========================================================================

export function handleIRequest(
  agent: AgentState,
  threadId: number,
  dst: number,
  reqDefId: number,
  argVars: number[],
  events: Event[],
  messages: OutgoingMessage[],
  config: RequestConfig
): void {
  const argValues = argVars.map((v) => getVar(agent, v));
  const requestId = uuidv4();

  const t = agent.threads.get(threadId)!;
  t.status = { tag: "Suspended", reason: { tag: "Request", requestId, dst } };

  const pending: PendingRequest = {
    requestId,
    reqDefId,
    args: argValues,
    fromAgentId: agent.agentId,
    fromAgentWhere: "",
  };

  const route = routeRequestToHandle(agent, threadId, reqDefId);
  if (route) {
    events.push({
      agentId: agent.agentId,
      kind: {
        tag: "IncomingRequest",
        ownerThreadId: route[0],
        request: pending,
        handlerDefTid: route[1],
      },
    });
  } else if (agent.parentAvailableRequests.has(reqDefId) && agent.parentAgentWhere) {
    // Forward to remote parent
    messages.push({
      toUrl: agent.parentAgentWhere,
      kind: {
        type: "Request",
        body: {
          request_id: requestId,
          request_def_id: String(reqDefId),
          request_def_where: config.selfBaseUrl,
          args: argValues as JsonValue[],
          from_agent_id: agent.agentId,
          from_agent_where: config.selfBaseUrl,
        },
      },
    });
  } else {
    console.warn(`no handle scope for request ${reqDefId}`);
  }
}
