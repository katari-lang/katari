import type { AgentState, Event, Signal } from "./types.js";
import type { Value } from "../value.js";
import {
  setVar, finishThread, resumeThread, spawnChildThread,
} from "./types.js";

// ===========================================================================
// Setup
// ===========================================================================

export function setupPar(
  agent: AgentState,
  threadId: number,
  dst: number,
  tids: number[],
  events: Event[]
): void {
  const t = agent.threads.get(threadId)!;
  t.status = {
    tag: "Suspended",
    reason: {
      tag: "Par",
      branchThreads: [...tids],
      results: new Array(tids.length).fill(undefined),
      dst,
    },
  };
  for (const tid of tids) {
    spawnChildThread(agent, tid, "Block", threadId, events);
  }
}

// ===========================================================================
// Branch signal
// ===========================================================================

export function processParBranchSignal(
  agent: AgentState,
  ownerThreadId: number,
  branchTid: number,
  signal: Signal,
  events: Event[]
): void {
  const t = agent.threads.get(ownerThreadId);
  if (!t || t.status.tag !== "Suspended" || t.status.reason.tag !== "Par") return;
  const reason = t.status.reason;

  switch (signal.tag) {
    case "Normal": {
      const idx = reason.branchThreads.indexOf(branchTid);
      if (idx !== -1) reason.results[idx] = signal.value;
      if (reason.results.every((r) => r !== undefined)) {
        setVar(agent, reason.dst, reason.results as Value[]);
        resumeThread(agent, ownerThreadId, events);
      }
      break;
    }
    case "FnReturn":
    case "HandleBreak": {
      // Cancel other branches
      for (const tid of reason.branchThreads) {
        if (tid !== branchTid) {
          events.push({ agentId: agent.agentId, kind: { tag: "Terminate", threadId: tid } });
        }
      }
      finishThread(agent, ownerThreadId, signal, events);
      break;
    }
    default:
      break;
  }
}
