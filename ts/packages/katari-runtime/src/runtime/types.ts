import type {
  IRModule,
  IRThread,
  IRHandleDef,
  IRForDef,
  ConstVal,
  ThreadKind,
} from "../ir.js";
import type { Value } from "../value.js";
import type { CapabilityRef, EscalationRef, JsonValue } from "katari-protocol";
import type { RuntimeLogger } from "../logger.js";

// ===========================================================================
// Agent State
// ===========================================================================

export interface AgentState {
  agentId: string;
  agentDefId: number;
  module: IRModule;
  vars: Map<number, Value>;
  threads: Map<number, ThreadState>;
  rootThreadId: number;
  // Protocol-level info
  delegationEndpoint: string | null; // parent's endpoint (for delegate_ack)
  delegationId: string | null; // parent's delegation id
  selfEndpoint: string;
  capabilityRefs: CapabilityRef[]; // capabilities available to this agent's children
}

// ===========================================================================
// Thread State
// ===========================================================================

export interface ThreadState {
  threadId: number;
  blockId: number; // IR block (thread def) being executed
  pc: number;
  parent: number | null;
  status: ThreadStatus;
}

// ===========================================================================
// Thread Status
// ===========================================================================

export type ThreadStatus = CallingStatus | RequestingStatus | CancelingStatus;

/** Thread is actively executing or waiting for a child */
export interface CallingStatus {
  tag: "CALLING";
  kind: CallingKind;
}

/** Thread is waiting for a request (escalation) response */
export interface RequestingStatus {
  tag: "REQUESTING";
  /** Which thread the request came from (null = this thread issued IRequest) */
  fromThread: number | null;
  /** The calling kind before entering REQUESTING state */
  previousState: CallingKind;
  /** Queued events that arrived while in REQUESTING state */
  eventQueue: RuntimeEvent[];
  /** Escalation tracking */
  escalationRef: EscalationRef | null;
}

/** Thread is being canceled — waiting for children to finish canceling */
export interface CancelingStatus {
  tag: "CANCELING";
  /** Event to fire after cancellation completes */
  nextAction: RuntimeEvent | null;
  /** Number of children we're waiting for canceled events from */
  pendingCancelCount: number;
}

// ===========================================================================
// Calling Kind — what kind of child call this thread is doing
// ===========================================================================

export type CallingKind =
  | BlockCallingKind
  | AgentCallingKind
  | HandleTargetCallingKind
  | HandleBodyCallingKind
  | HandleThenCallingKind
  | ForBodyCallingKind
  | ForThenCallingKind
  | ParallelCallingKind
  | DelegatingCallingKind;

export interface BlockCallingKind {
  tag: "BLOCK";
  childThreadId: number;
  dst: number;
}

export interface AgentCallingKind {
  tag: "AGENT";
  childAgentId: string;
  dst: number;
}

export interface HandleTargetCallingKind {
  tag: "HANDLE_TARGET";
  handleDefId: number;
  childThreadId: number;
  dst: number;
  stateVars: Map<number, Value>;
}

export interface HandleBodyCallingKind {
  tag: "HANDLE_BODY";
  handleDefId: number;
  targetThreadId: number;
  handlerThreadId: number;
  dst: number;
  stateVars: Map<number, Value>;
  /** Who issued the request that triggered this handler */
  requesterInfo: RequesterInfo;
}

export interface HandleThenCallingKind {
  tag: "HANDLE_THEN";
  handleDefId: number;
  thenThreadId: number;
  dst: number;
  stateVars: Map<number, Value>;
  /** Event to fire after then clause completes */
  nextAction: RuntimeEvent;
}

export interface ForBodyCallingKind {
  tag: "FOR_BODY";
  forDefId: number;
  childThreadId: number;
  currentIndex: number;
  minLength: number;
  dst: number;
}

export interface ForThenCallingKind {
  tag: "FOR_THEN";
  forDefId: number;
  thenThreadId: number;
  dst: number;
}

export interface ParallelCallingKind {
  tag: "PARALLEL";
  branchThreadIds: number[];
  results: (Value | undefined)[];
  dst: number;
}

export interface DelegatingCallingKind {
  tag: "DELEGATING";
  delegationId: string;
  dst: number;
}

// ===========================================================================
// Requester Info — tracks who issued the escalation being handled
// ===========================================================================

export interface RequesterInfo {
  /** The escalation ref (for sending escalate_ack) */
  escalationRef: EscalationRef | null;
  /** The escalation endpoint (for sending escalate_ack) */
  escalationEndpoint: string | null;
  /** Internal thread that issued IRequest (for internal routing) */
  internalThreadId: number | null;
  /** Internal request ID (for matching) */
  internalRequestId: string | null;
}

// ===========================================================================
// Runtime Events — internal events between parent/child threads
// ===========================================================================

export type RuntimeEvent =
  | { tag: "call"; blockId: number }
  | { tag: "cancel" }
  | { tag: "completed"; value: Value }
  | { tag: "returned"; value: Value }
  | { tag: "continue"; value: Value }
  | { tag: "continued"; value: Value; mutations: [number, number][] }
  | { tag: "broken"; value: Value }
  | { tag: "for_continued"; mutations: [number, number][] }
  | { tag: "for_broken"; value: Value }
  | {
      tag: "requested";
      reqDefId: number;
      args: Record<string, Value>;
      requestId: string;
      fromThreadId: number | null;
      escalationRef: EscalationRef | null;
      escalationEndpoint: string | null;
    }
  | { tag: "canceled" };

// ===========================================================================
// Outgoing Actions — result of synchronous event processing
// ===========================================================================

/** Protocol-level outbound actions — processed via KatariServer */
export type ProtocolAction =
  | {
      tag: "ProtocolDelegate";
      targetEndpoint: string;
      agentDefId: string;
      input: JsonValue;
      capabilityRefs: CapabilityRef[];
      delegationId: string;
    }
  | {
      tag: "ProtocolEscalate";
      capabilityRef: CapabilityRef;
      input: JsonValue;
      escalationId: string;
    }
  | { tag: "ProtocolDelegateAck"; agentId: string; output: JsonValue }
  | {
      tag: "ProtocolEscalateAck";
      escalationRef: EscalationRef;
      escalationEndpoint: string;
      output: JsonValue;
    }
  | {
      tag: "ProtocolThrow";
      delegationEndpoint: string;
      delegationId: string;
      message: string;
    };

export type OutgoingAction =
  | ProtocolAction
  | { tag: "AgentCompleted"; agentId: string; value: Value }
  | { tag: "AgentError"; agentId: string }
  | {
      tag: "SpawnAgent";
      parentAgentId: string;
      parentThreadId: number;
      agentDefId: number;
      args: Record<string, Value>;
      dst: number;
    }
  | { tag: "TerminateAgent"; childAgentId: string };

// ===========================================================================
// Dispatch Context — injected by Runtime to handle Call/Request resolution
// ===========================================================================

/**
 * Handles ICall instructions: resolves primitives, internal agents, external
 * delegation. Returns true if the call was handled synchronously (primitive),
 * false if the thread is now suspended.
 */
export type CallHandler = (
  agent: AgentState,
  threadId: number,
  dst: number,
  agentDefId: number,
  args: Record<string, Value>,
  actions: OutgoingAction[],
) => boolean;

/**
 * Handles requests that reach the root thread (no parent).
 * Typically escalates via the protocol.
 */
export type RootRequestHandler = (
  agent: AgentState,
  threadId: number,
  event: RuntimeEvent & { tag: "requested" },
  actions: OutgoingAction[],
) => void;

/** Context for dispatch operations — provided by Runtime */
export interface DispatchContext {
  callHandler: CallHandler;
  rootRequestHandler: RootRequestHandler;
  logger: RuntimeLogger;
}

// ===========================================================================
// Helper functions
// ===========================================================================

export function getVar(agent: AgentState, v: number): Value {
  return agent.vars.get(v) ?? null;
}

export function setVar(agent: AgentState, v: number, val: Value): void {
  agent.vars.set(v, val);
}

export function findThread(
  module: IRModule,
  tid: number,
): IRThread | undefined {
  return module.threads.find((t) => t.id === tid);
}

export function findHandle(
  module: IRModule,
  hid: number,
): IRHandleDef | undefined {
  return module.handles.find((h) => h.id === hid);
}

export function findFor(module: IRModule, fid: number): IRForDef | undefined {
  return module.fors.find((f) => f.id === fid);
}

export function constAsString(consts: ConstVal[], cid: number): string {
  const c = consts[cid];
  return c?.tag === "Str" ? c.value : "";
}

// ===========================================================================
// Thread lifecycle helpers
// ===========================================================================

/** Create a new child thread and return it */
export function createThread(
  agent: AgentState,
  blockId: number,
  parent: number | null,
): ThreadState {
  const thread: ThreadState = {
    threadId: blockId, // Thread ID = Block ID for now
    blockId,
    pc: 0,
    parent,
    status: {
      tag: "CALLING",
      kind: { tag: "BLOCK", childThreadId: -1, dst: -1 },
    },
  };
  // Set initial status to a simple running state (caller will adjust)
  agent.threads.set(blockId, thread);
  return thread;
}

/** Remove a thread from the agent */
export function deleteThread(agent: AgentState, threadId: number): void {
  agent.threads.delete(threadId);
}

/** Get all child thread IDs of a given thread */
export function getChildThreadIds(
  agent: AgentState,
  parentId: number,
): number[] {
  const children: number[] = [];
  for (const [id, t] of agent.threads) {
    if (t.parent === parentId) children.push(id);
  }
  return children;
}

// ===========================================================================
// External agent routing
// ===========================================================================

export interface ExternalAgentRef {
  agent_def_id: string;
  agent_def_where: string;
}
