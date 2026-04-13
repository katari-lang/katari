import type { IRModule, IRThread, IRHandleDef, IRForDef, ConstVal, ThreadKind } from "../ir.js";
import type { Value } from "../value.js";

// ===========================================================================
// Agent / Thread State
// ===========================================================================

export type AgentStatus =
  | { tag: "Running" }
  | { tag: "Completed"; value: Value }
  | { tag: "Error" };

export interface AgentState {
  agentId: string;
  agentDefId: number;
  module: IRModule;
  vars: Map<number, Value>;
  threads: Map<number, ThreadState>;
  rootThread: number;
  parentAgentId: string;
  parentAgentWhere: string;
  children: Map<string, number>; // childAgentId → spawning thread
  parentAvailableRequests: Set<number>;
  selfWhere: string;
  status: AgentStatus;
}

export interface ThreadState {
  threadId: number;
  kind: ThreadKind;
  pc: number;
  status: ThreadStatus;
  parent: number | null;
}

export type ThreadStatus =
  | { tag: "Running" }
  | { tag: "Suspended"; reason: SuspendReason };

export type SuspendReason =
  | {
      tag: "Handle";
      handleDefId: number;
      dst: number;
      phase: HandlePhase;
      stateVars: Map<number, Value>;
    }
  | {
      tag: "For";
      forDefId: number;
      currentIndex: number;
      minLength: number;
      dst: number;
    }
  | {
      tag: "Par";
      branchThreads: number[];
      results: (Value | undefined)[];
      dst: number;
    }
  | { tag: "Call"; childAgentId: string; dst: number }
  | { tag: "Request"; requestId: string; dst: number };

export type HandlePhase =
  | { tag: "RunningBody"; bodyThread: number }
  | {
      tag: "RunningHandler";
      bodyThread: number;
      handlerThread: number;
      requester: RequestOrigin;
    }
  | { tag: "RunningThen"; thenThread: number };

export interface RequestOrigin {
  fromAgentId: string;
  fromAgentWhere: string;
  requestId: string;
}

export interface PendingRequest {
  requestId: string;
  reqDefId: number;
  args: Record<string, Value>;
  fromAgentId: string;
  fromAgentWhere: string;
}

// ===========================================================================
// Signals
// ===========================================================================

export type Signal =
  | { tag: "Normal"; value: Value }
  | { tag: "FnReturn"; value: Value }
  | { tag: "HandleBreak"; value: Value }
  | { tag: "Continue"; value: Value; mutations: [number, number][] }
  | { tag: "ForBreak"; value: Value }
  | { tag: "ForContinue"; mutations: [number, number][] }
  | { tag: "Cancelled" };

// ===========================================================================
// Events
// ===========================================================================

export interface Event {
  agentId: string;
  kind: EventKind;
}

export type EventKind =
  | { tag: "Execute"; threadId: number }
  | {
      tag: "ThreadCompleted";
      parentId: number;
      childId: number;
      childKind: ThreadKind;
      signal: Signal;
    }
  | { tag: "Terminate"; threadId: number }
  | {
      tag: "IncomingRequest";
      ownerThreadId: number;
      request: PendingRequest;
      handlerDefTid: number;
    }
  | { tag: "Reply"; threadId: number; requestId: string; value: Value }
  | {
      tag: "SpawnChildAgent";
      childAgentId: string;
      agentDefId: number;
      args: Record<string, Value>;
    }
  | { tag: "AgentCompleted" }
  | {
      tag: "ChildAgentCompleted";
      threadId: number;
      childAgentId: string;
      result: Value;
    }
  | {
      tag: "TerminateAgent";
      agentId: string;
      fromAgentId: string;
      fromAgentWhere: string;
    };

// ===========================================================================
// Helpers
// ===========================================================================

export function getVar(agent: AgentState, v: number): Value {
  return agent.vars.get(v) ?? null;
}

export function setVar(agent: AgentState, v: number, val: Value): void {
  agent.vars.set(v, val);
}

export function isRunning(t: ThreadState): boolean {
  return t.status.tag === "Running";
}

export function constAsString(consts: ConstVal[], cid: number): string {
  const c = consts[cid];
  return c?.tag === "Str" ? c.value : "";
}

export function findThread(module: IRModule, tid: number): IRThread | undefined {
  return module.threads.find((t) => t.id === tid);
}

export function findHandle(module: IRModule, hid: number): IRHandleDef | undefined {
  return module.handles.find((h) => h.id === hid);
}

export function findFor(module: IRModule, fid: number): IRForDef | undefined {
  return module.fors.find((f) => f.id === fid);
}

// ===========================================================================
// Thread lifecycle
// ===========================================================================

export function finishThread(
  agent: AgentState,
  threadId: number,
  signal: Signal,
  events: Event[]
): void {
  if (threadId === agent.rootThread) {
    if (signal.tag === "Normal" || signal.tag === "FnReturn") {
      agent.status = { tag: "Completed", value: signal.value };
    } else {
      agent.status = { tag: "Error" };
    }
    agent.threads.delete(threadId);
    events.push({ agentId: agent.agentId, kind: { tag: "AgentCompleted" } });
  } else {
    const t = agent.threads.get(threadId);
    if (!t) return;
    const kind = t.kind;
    const parent = t.parent;
    agent.threads.delete(threadId);
    if (parent !== null) {
      events.push({
        agentId: agent.agentId,
        kind: {
          tag: "ThreadCompleted",
          parentId: parent,
          childId: threadId,
          childKind: kind,
          signal,
        },
      });
    }
  }
}

export function resumeThread(
  agent: AgentState,
  threadId: number,
  events: Event[]
): void {
  const t = agent.threads.get(threadId);
  if (t) t.status = { tag: "Running" };
  events.push({
    agentId: agent.agentId,
    kind: { tag: "Execute", threadId },
  });
}

export function spawnChildThread(
  agent: AgentState,
  tid: number,
  kind: ThreadKind,
  parent: number,
  events: Event[]
): void {
  agent.threads.set(tid, {
    threadId: tid,
    kind,
    pc: 0,
    status: { tag: "Running" },
    parent,
  });
  events.push({
    agentId: agent.agentId,
    kind: { tag: "Execute", threadId: tid },
  });
}

// ===========================================================================
// Request routing utilities
// ===========================================================================

export function routeRequestToHandle(
  agent: AgentState,
  sourceThreadId: number,
  reqDefId: number
): [number, number] | null {
  let current = sourceThreadId;
  for (;;) {
    const t = agent.threads.get(current);
    if (!t || t.parent === null) return null;
    const parentId = t.parent;
    const parent = agent.threads.get(parentId);
    if (
      parent?.status.tag === "Suspended" &&
      parent.status.reason.tag === "Handle" &&
      parent.status.reason.phase.tag !== "RunningThen"
    ) {
      const hdef = findHandle(agent.module, parent.status.reason.handleDefId);
      if (hdef) {
        const match = hdef.reqCases.find(([rid]) => rid === reqDefId);
        if (match) return [parentId, match[1]];
      }
    }
    current = parentId;
  }
}

export function findRequestThread(
  agent: AgentState,
  requestId: string
): number | null {
  for (const [id, t] of agent.threads) {
    if (
      t.status.tag === "Suspended" &&
      t.status.reason.tag === "Request" &&
      t.status.reason.requestId === requestId
    ) {
      return id;
    }
  }
  return null;
}

export function isHeldByHandler(
  agent: AgentState,
  threadId: number
): boolean {
  let current = threadId;
  for (;;) {
    const t = agent.threads.get(current);
    if (!t || t.parent === null) return false;
    const parentId = t.parent;
    const parent = agent.threads.get(parentId);
    if (
      parent &&
      parent.status.tag === "Suspended" &&
      parent.status.reason.tag === "Handle" &&
      parent.status.reason.phase.tag === "RunningHandler" &&
      current === parent.status.reason.phase.bodyThread
    ) {
      return true;
    }
    current = parentId;
  }
}
