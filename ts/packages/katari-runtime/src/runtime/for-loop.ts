import type { AgentState, Event, Signal } from "./types.js";
import {
  getVar, setVar, findFor, findThread,
  finishThread, resumeThread, spawnChildThread,
} from "./types.js";

// ===========================================================================
// Setup
// ===========================================================================

export function setupFor(
  agent: AgentState,
  threadId: number,
  dst: number,
  fid: number,
  events: Event[]
): void {
  const fdef = findFor(agent.module, fid)!;

  // Initialize state vars
  for (let i = 0; i < fdef.stateVars.length; i++) {
    setVar(agent, fdef.stateVars[i]!, getVar(agent, fdef.stateInits[i]!));
  }

  // Calculate min array length
  let minLen = Infinity;
  for (const arrVar of fdef.arrays) {
    const arr = getVar(agent, arrVar);
    minLen = Math.min(minLen, Array.isArray(arr) ? arr.length : 0);
  }
  if (!isFinite(minLen)) minLen = 0;

  const t = agent.threads.get(threadId)!;
  t.status = {
    tag: "Suspended",
    reason: { tag: "For", forDefId: fid, currentIndex: 0, minLength: minLen, dst },
  };

  if (minLen > 0) {
    startForIteration(agent, threadId, fid, 0, events);
  } else {
    finishForLoop(agent, threadId, fid, dst, events);
  }
}

// ===========================================================================
// Iteration
// ===========================================================================

function startForIteration(
  agent: AgentState,
  parentThreadId: number,
  fid: number,
  index: number,
  events: Event[]
): void {
  const fdef = findFor(agent.module, fid)!;
  for (let i = 0; i < fdef.iterVars.length; i++) {
    const arr = getVar(agent, fdef.arrays[i]!);
    if (Array.isArray(arr)) {
      setVar(agent, fdef.iterVars[i]!, arr[index] ?? null);
    }
  }
  spawnChildThread(agent, fdef.body, "ForBody", parentThreadId, events);
}

function advanceFor(
  agent: AgentState,
  ownerThreadId: number,
  fid: number,
  currentIndex: number,
  minLength: number,
  dst: number,
  events: Event[]
): void {
  const nextIndex = currentIndex + 1;
  if (nextIndex < minLength) {
    const t = agent.threads.get(ownerThreadId)!;
    if (t.status.tag === "Suspended" && t.status.reason.tag === "For") {
      t.status.reason.currentIndex = nextIndex;
    }
    startForIteration(agent, ownerThreadId, fid, nextIndex, events);
  } else {
    finishForLoop(agent, ownerThreadId, fid, dst, events);
  }
}

function finishForLoop(
  agent: AgentState,
  ownerThreadId: number,
  fid: number,
  dst: number,
  events: Event[]
): void {
  const fdef = findFor(agent.module, fid)!;
  if (fdef.then !== null) {
    spawnChildThread(agent, fdef.then, "ForThen", ownerThreadId, events);
  } else {
    setVar(agent, dst, null);
    resumeThread(agent, ownerThreadId, events);
  }
}

// ===========================================================================
// Signals
// ===========================================================================

export function processForBodySignal(
  agent: AgentState,
  ownerThreadId: number,
  signal: Signal,
  events: Event[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "For") return;
  const reason = t.status.reason;

  switch (signal.tag) {
    case "ForContinue":
      for (const [sv, nv] of signal.mutations) setVar(agent, sv, getVar(agent, nv));
      advanceFor(agent, ownerThreadId, reason.forDefId, reason.currentIndex, reason.minLength, reason.dst, events);
      break;
    case "Normal":
      advanceFor(agent, ownerThreadId, reason.forDefId, reason.currentIndex, reason.minLength, reason.dst, events);
      break;
    case "ForBreak":
      setVar(agent, reason.dst, signal.value);
      resumeThread(agent, ownerThreadId, events);
      break;
    case "FnReturn":
    case "HandleBreak":
      finishThread(agent, ownerThreadId, signal, events);
      break;
    default:
      break;
  }
}

export function processForThenSignal(
  agent: AgentState,
  ownerThreadId: number,
  signal: Signal,
  events: Event[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "For") return;

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
