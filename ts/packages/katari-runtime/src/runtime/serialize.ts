import type { CapabilityRef, EscalationRef } from "katari-protocol";
import type { Value } from "../value.js";
import type {
  AgentState, ThreadState, ThreadStatus, CallingKind, RuntimeEvent,
  RequesterInfo,
} from "./types.js";
import type { IRModule } from "../ir.js";

// ===========================================================================
// Serialized types — JSON-safe representations of runtime state
// ===========================================================================

export interface SerializedAgentState {
  agentId: string;
  agentDefId: number;
  vars: [number, Value][];
  threads: [number, SerializedThreadState][];
  rootThreadId: number;
  delegationEndpoint: string | null;
  delegationId: string | null;
  selfEndpoint: string;
  capabilityRefs: CapabilityRef[];
}

export interface SerializedThreadState {
  threadId: number;
  blockId: number;
  pc: number;
  parent: number | null;
  status: SerializedThreadStatus;
}

// ThreadStatus is already a tagged union — serialize as-is but convert Value Maps
type SerializedThreadStatus =
  | { tag: "CALLING"; kind: SerializedCallingKind }
  | { tag: "REQUESTING"; fromThread: number | null; previousState: SerializedCallingKind; eventQueue: RuntimeEvent[]; escalationRef: EscalationRef | null }
  | { tag: "CANCELING"; nextAction: RuntimeEvent | null; pendingCancelCount: number };

type SerializedCallingKind =
  | { tag: "BLOCK"; childThreadId: number; dst: number }
  | { tag: "AGENT"; childAgentId: string; dst: number }
  | { tag: "HANDLE_TARGET"; handleDefId: number; childThreadId: number; dst: number; stateVars: [number, Value][] }
  | { tag: "HANDLE_BODY"; handleDefId: number; targetThreadId: number; handlerThreadId: number; dst: number; stateVars: [number, Value][]; requesterInfo: RequesterInfo }
  | { tag: "HANDLE_THEN"; handleDefId: number; thenThreadId: number; dst: number; stateVars: [number, Value][]; nextAction: RuntimeEvent }
  | { tag: "FOR_BODY"; forDefId: number; childThreadId: number; currentIndex: number; minLength: number; dst: number }
  | { tag: "FOR_THEN"; forDefId: number; thenThreadId: number; dst: number }
  | { tag: "PARALLEL"; branchThreadIds: number[]; results: (Value | undefined)[]; dst: number }
  | { tag: "DELEGATING"; delegationId: string; dst: number };

// ===========================================================================
// Serialize
// ===========================================================================

export function serializeAgentState(agent: AgentState): SerializedAgentState {
  return {
    agentId: agent.agentId,
    agentDefId: agent.agentDefId,
    vars: Array.from(agent.vars.entries()),
    threads: Array.from(agent.threads.entries()).map(
      ([id, t]) => [id, serializeThread(t)]
    ),
    rootThreadId: agent.rootThreadId,
    delegationEndpoint: agent.delegationEndpoint,
    delegationId: agent.delegationId,
    selfEndpoint: agent.selfEndpoint,
    capabilityRefs: agent.capabilityRefs,
  };
}

function serializeThread(t: ThreadState): SerializedThreadState {
  return {
    threadId: t.threadId,
    blockId: t.blockId,
    pc: t.pc,
    parent: t.parent,
    status: serializeStatus(t.status),
  };
}

function serializeStatus(s: ThreadStatus): SerializedThreadStatus {
  switch (s.tag) {
    case "CALLING":
      return { tag: "CALLING", kind: serializeCallingKind(s.kind) };
    case "REQUESTING":
      return {
        tag: "REQUESTING",
        fromThread: s.fromThread,
        previousState: serializeCallingKind(s.previousState),
        eventQueue: s.eventQueue,
        escalationRef: s.escalationRef,
      };
    case "CANCELING":
      return {
        tag: "CANCELING",
        nextAction: s.nextAction,
        pendingCancelCount: s.pendingCancelCount,
      };
  }
}

function serializeCallingKind(k: CallingKind): SerializedCallingKind {
  switch (k.tag) {
    case "BLOCK":
    case "AGENT":
    case "FOR_THEN":
    case "DELEGATING":
      return k; // Already JSON-safe
    case "HANDLE_TARGET":
      return { ...k, stateVars: Array.from(k.stateVars.entries()) };
    case "HANDLE_BODY":
      return { ...k, stateVars: Array.from(k.stateVars.entries()) };
    case "HANDLE_THEN":
      return { ...k, stateVars: Array.from(k.stateVars.entries()) };
    case "FOR_BODY":
    case "PARALLEL":
      return k;
  }
}

// ===========================================================================
// Deserialize
// ===========================================================================

export function deserializeAgentState(
  s: SerializedAgentState,
  module: IRModule,
): AgentState {
  return {
    agentId: s.agentId,
    agentDefId: s.agentDefId,
    module,
    vars: new Map(s.vars),
    threads: new Map(s.threads.map(([id, t]) => [id, deserializeThread(t)])),
    rootThreadId: s.rootThreadId,
    delegationEndpoint: s.delegationEndpoint,
    delegationId: s.delegationId,
    selfEndpoint: s.selfEndpoint,
    capabilityRefs: s.capabilityRefs,
  };
}

function deserializeThread(s: SerializedThreadState): ThreadState {
  return {
    threadId: s.threadId,
    blockId: s.blockId,
    pc: s.pc,
    parent: s.parent,
    status: deserializeStatus(s.status),
  };
}

function deserializeStatus(s: SerializedThreadStatus): ThreadStatus {
  switch (s.tag) {
    case "CALLING":
      return { tag: "CALLING", kind: deserializeCallingKind(s.kind) };
    case "REQUESTING":
      return {
        tag: "REQUESTING",
        fromThread: s.fromThread,
        previousState: deserializeCallingKind(s.previousState),
        eventQueue: s.eventQueue,
        escalationRef: s.escalationRef,
      };
    case "CANCELING":
      return {
        tag: "CANCELING",
        nextAction: s.nextAction,
        pendingCancelCount: s.pendingCancelCount,
      };
  }
}

function deserializeCallingKind(s: SerializedCallingKind): CallingKind {
  switch (s.tag) {
    case "BLOCK":
    case "AGENT":
    case "FOR_BODY":
    case "FOR_THEN":
    case "PARALLEL":
    case "DELEGATING":
      return s;
    case "HANDLE_TARGET":
      return { ...s, stateVars: new Map(s.stateVars) };
    case "HANDLE_BODY":
      return { ...s, stateVars: new Map(s.stateVars) };
    case "HANDLE_THEN":
      return { ...s, stateVars: new Map(s.stateVars) };
  }
}
