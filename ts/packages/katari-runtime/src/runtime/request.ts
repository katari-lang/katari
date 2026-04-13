import { v4 as uuidv4 } from "uuid";
import type { OutgoingMessage, JsonValue, EffectRef } from "katari-protocol";
import type { IRModule } from "../ir.js";
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
  module: IRModule | null;
  servers: Map<string, string>;
  agentNameMap: Map<string, number>;
  schemas: Map<string, JsonValue>;
}

// ===========================================================================
// Helper: evaluate named arg pairs into a Record
// ===========================================================================

function evalNamedArgs(
  agent: AgentState,
  namedArgs: [string, number][]
): Record<string, Value> {
  const result: Record<string, Value> = {};
  for (const [name, vid] of namedArgs) {
    result[name] = getVar(agent, vid);
  }
  return result;
}

// ===========================================================================
// Helper: build EffectRef[] from a set of numeric request IDs
// ===========================================================================

function buildEffectRefs(requestIds: Set<number>, config: RequestConfig): EffectRef[] {
  if (!config.module) return [];
  const refs: EffectRef[] = [];
  for (const rid of requestIds) {
    const reqDef = config.module.requests.find((r) => r.id === rid);
    if (!reqDef) continue;
    if (reqDef.from) {
      // External request: "discord:on_message" → { request_id: "on_message", request_where: discordUrl }
      const colonIdx = reqDef.from.indexOf(":");
      if (colonIdx !== -1) {
        const serverKey = reqDef.from.substring(0, colonIdx);
        const localName = reqDef.from.substring(colonIdx + 1);
        const serverUrl = config.servers.get(serverKey);
        if (serverUrl) {
          refs.push({ request_id: localName, request_where: serverUrl });
        }
      }
    } else {
      // Internal request
      refs.push({ request_id: String(rid), request_where: config.selfBaseUrl });
    }
  }
  return refs;
}

// ===========================================================================
// Helper: resolve external agent ref by qualified name
// ===========================================================================

function resolveAgentRef(agentName: string, config: RequestConfig): Value {
  const numId = config.agentNameMap.get(agentName);
  if (numId === undefined) return null;

  const extRef = config.externalAgents.get(numId);
  if (!extRef) return null;

  const schema = config.schemas.get(agentName) as Record<string, JsonValue> | undefined;
  return {
    url: extRef.agent_def_where,
    agent_def_id: extRef.agent_def_id,
    name: agentName,
    description: (schema?.description as string) ?? "",
    arg_type: schema?.arg_type ?? null,
  };
}

// ===========================================================================
// ICall — agent invocation
// ===========================================================================

export function handleICall(
  agent: AgentState,
  threadId: number,
  dst: number,
  agentDefId: number,
  namedArgs: [string, number][],
  events: Event[],
  messages: OutgoingMessage[],
  config: RequestConfig
): void {
  const agentDef = agent.module.agents.find((a) => a.id === agentDefId);

  // Reverse-lookup agent name from agentNameMap for primitives (not in module.agents)
  const agentNameFromMap = (() => {
    for (const [name, id] of config.agentNameMap) {
      if (id === agentDefId) return name;
    }
    return null;
  })();

  // prim.ref_agent — special case (needs runtime state)
  if (agentNameFromMap === "prim.ref_agent") {
    const agentName = getVar(agent, namedArgs[0]![1]) as string;
    setVar(agent, dst, resolveAgentRef(agentName, config));
    return;
  }

  // Primitive agents (synchronous)
  const primName = agentNameFromMap ?? agentDef?.name;
  if (primName?.startsWith("prim.")) {
    const argValues = namedArgs.map(([, v]) => getVar(agent, v));
    const result = callPrimitive(primName, argValues);
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

  // Build named args object
  const argsObj = evalNamedArgs(agent, namedArgs);

  // External agent?
  const externalRef = config.externalAgents.get(agentDefId);
  if (externalRef) {
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
          args: argsObj as Record<string, JsonValue>,
          parent_agent_id: agent.agentId,
          parent_agent_where: config.selfBaseUrl,
          with_effects: buildEffectRefs(agent.parentAvailableRequests, config),
        },
        parentAgentId: agent.agentId,
        provisionalChildId: childAgentId,
      },
    });
    return;
  }

  // Local non-primitive agent
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
      args: argsObj,
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
  namedArgs: [string, number][],
  events: Event[],
  messages: OutgoingMessage[],
  config: RequestConfig
): void {
  const argsObj = evalNamedArgs(agent, namedArgs);
  const requestId = uuidv4();

  const t = agent.threads.get(threadId)!;
  t.status = { tag: "Suspended", reason: { tag: "Request", requestId, dst } };

  const pending: PendingRequest = {
    requestId,
    reqDefId,
    args: argsObj,
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
  } else if (agent.parentAgentWhere) {
    // No local handler — forward to parent (type system guarantees an ancestor handles it)
    messages.push({
      toUrl: agent.parentAgentWhere,
      kind: {
        type: "Request",
        body: {
          request_id: requestId,
          request_def_id: String(reqDefId),
          request_def_where: config.selfBaseUrl,
          args: argsObj as Record<string, JsonValue>,
          from_agent_id: agent.agentId,
          from_agent_where: config.selfBaseUrl,
        },
      },
    });
  } else {
    console.warn(`no handle scope for request ${reqDefId}`);
  }
}
