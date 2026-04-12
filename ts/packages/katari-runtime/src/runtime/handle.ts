import type { OutgoingMessage, JsonValue } from "katari-protocol";
import type { AgentState, Event, PendingRequest, RequestOrigin, Signal } from "./types.js";
import type { Value } from "../value.js";
import {
  getVar, setVar, findHandle, findThread, findRequestThread,
  finishThread, resumeThread, spawnChildThread,
} from "./types.js";

// ===========================================================================
// Setup
// ===========================================================================

export function setupHandle(
  agent: AgentState,
  threadId: number,
  dst: number,
  hid: number,
  events: Event[]
): void {
  const hdef = findHandle(agent.module, hid)!;

  // Initialize state vars
  const stateVars = new Map<number, Value>();
  for (let i = 0; i < hdef.stateVars.length; i++) {
    stateVars.set(hdef.stateVars[i]!, getVar(agent, hdef.stateInits[i]!));
  }

  // Suspend parent
  const t = agent.threads.get(threadId);
  if (t) {
    t.status = {
      tag: "Suspended",
      reason: {
        tag: "Handle",
        handleDefId: hid,
        dst,
        phase: { tag: "RunningBody", bodyThread: hdef.body },
        stateVars,
      },
    };
  }

  spawnChildThread(agent, hdef.body, "HandlerTarget", threadId, events);
}

// ===========================================================================
// Dispatch incoming request to handler
// ===========================================================================

export function dispatchRequest(
  agent: AgentState,
  threadId: number,
  handlerTid: number,
  request: PendingRequest,
  events: Event[]
): void {
  const t = agent.threads.get(threadId);
  if (
    !t ||
    t.status.tag !== "Suspended" ||
    t.status.reason.tag !== "Handle" ||
    t.status.reason.phase.tag !== "RunningBody"
  )
    return;

  const bodyThread = t.status.reason.phase.bodyThread;

  // Copy state vars to agent.vars
  for (const [sv, val] of t.status.reason.stateVars) {
    setVar(agent, sv, val);
  }

  // Bind request args to handler params
  const handlerIr = findThread(agent.module, handlerTid)!;
  for (let i = 0; i < handlerIr.params.length && i < request.args.length; i++) {
    setVar(agent, handlerIr.params[i]!, request.args[i]!);
  }

  // Update phase
  t.status.reason.phase = {
    tag: "RunningHandler",
    bodyThread,
    handlerThread: handlerTid,
    requester: {
      fromAgentId: request.fromAgentId,
      fromAgentWhere: request.fromAgentWhere,
      requestId: request.requestId,
    },
  };

  spawnChildThread(agent, handlerTid, "RequestHandler", threadId, events);
}

// ===========================================================================
// Handler signal (RequestHandler thread completed)
// ===========================================================================

export function processHandlerSignal(
  agent: AgentState,
  ownerThreadId: number,
  signal: Signal,
  events: Event[],
  messages: OutgoingMessage[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "Handle") return;
  const reason = t.status.reason;
  const phase = reason.phase;

  switch (signal.tag) {
    case "Normal":
      // Treat as Continue(value, [])
      processHandlerSignal(
        agent, ownerThreadId,
        { tag: "Continue", value: signal.value, mutations: [] },
        events, messages
      );
      break;

    case "Continue": {
      // Apply mutations to handle state
      for (const [sv, nv] of signal.mutations) {
        const val = getVar(agent, nv);
        reason.stateVars.set(sv, val);
      }

      if (phase.tag === "RunningHandler") {
        routeReply(agent, phase.requester, signal.value, events, messages);
        reason.phase = { tag: "RunningBody", bodyThread: phase.bodyThread };
      }
      break;
    }

    case "HandleBreak":
      if (phase.tag === "RunningHandler") {
        events.push({
          agentId: agent.agentId,
          kind: { tag: "Terminate", threadId: phase.bodyThread },
        });
      }
      setVar(agent, reason.dst, signal.value);
      resumeThread(agent, ownerThreadId, events);
      break;

    case "FnReturn":
      if (phase.tag === "RunningHandler") {
        events.push({
          agentId: agent.agentId,
          kind: { tag: "Terminate", threadId: phase.bodyThread },
        });
      }
      finishThread(agent, ownerThreadId, signal, events);
      break;

    default:
      break;
  }
}

// ===========================================================================
// Body signal (HandlerTarget thread completed)
// ===========================================================================

export function processHandleBodySignal(
  agent: AgentState,
  ownerThreadId: number,
  signal: Signal,
  events: Event[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "Handle") return;
  const reason = t.status.reason;
  const hdef = findHandle(agent.module, reason.handleDefId)!;

  switch (signal.tag) {
    case "Normal":
      if (hdef.then !== null) {
        const thenIr = findThread(agent.module, hdef.then)!;
        if (thenIr.params.length > 0) {
          setVar(agent, thenIr.params[0]!, signal.value);
        }
        reason.phase = { tag: "RunningThen", thenThread: hdef.then };
        spawnChildThread(agent, hdef.then, "HandleThen", ownerThreadId, events);
      } else {
        setVar(agent, reason.dst, signal.value);
        resumeThread(agent, ownerThreadId, events);
      }
      break;
    case "FnReturn":
      finishThread(agent, ownerThreadId, signal, events);
      break;
    default:
      break;
  }
}

// ===========================================================================
// Then signal (HandleThen thread completed)
// ===========================================================================

export function processHandleThenSignal(
  agent: AgentState,
  ownerThreadId: number,
  signal: Signal,
  events: Event[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "Handle") return;

  switch (signal.tag) {
    case "Normal":
      setVar(agent, t.status.reason.dst, signal.value);
      resumeThread(agent, ownerThreadId, events);
      break;
    case "FnReturn":
      finishThread(agent, ownerThreadId, signal, events);
      break;
    default:
      break;
  }
}

// ===========================================================================
// Route reply back to requester
// ===========================================================================

function routeReply(
  agent: AgentState,
  requester: RequestOrigin,
  value: Value,
  events: Event[],
  messages: OutgoingMessage[]
): void {
  if (requester.fromAgentId === agent.agentId) {
    // Internal: find waiting thread and resume
    const waitingTid = findRequestThread(agent, requester.requestId);
    if (waitingTid !== null) {
      const t = agent.threads.get(waitingTid);
      if (t?.status.tag === "Suspended" && t.status.reason.tag === "Request") {
        setVar(agent, t.status.reason.dst, value);
        resumeThread(agent, waitingTid, events);
      }
    }
  } else {
    // External: push outgoing reply
    messages.push({
      toUrl: requester.fromAgentWhere,
      kind: {
        type: "Reply",
        body: {
          request_id: requester.requestId,
          result: value as JsonValue,
          from_agent_id: agent.agentId,
          from_agent_where: agent.selfWhere,
          agent_id: requester.fromAgentId,
        },
      },
    });
  }
}
