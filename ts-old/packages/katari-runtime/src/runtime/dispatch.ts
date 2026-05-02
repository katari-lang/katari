import type { JsonValue } from "katari-protocol";
import type {
  AgentState,
  ThreadState,
  CallingKind,
  RuntimeEvent,
  OutgoingAction,
  AgentCallingKind,
  HandleTargetCallingKind,
  HandleBodyCallingKind,
  ForBodyCallingKind,
  ParallelCallingKind,
  RequesterInfo,
  DispatchContext,
} from "./types.js";
import {
  setVar,
  getVar,
  deleteThread,
  getChildThreadIds,
  createThread,
} from "./types.js";
import type { Value } from "../value.js";
import { executeThread } from "./execute.js";

// ===========================================================================
// fireEvent — synchronous event dispatch (public API)
//
// The core loop: fire event on thread → parent handles it based on
// CallingKind → may fire more events (synchronous recursion)
// ===========================================================================

export function fireEvent(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  event: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  const thread = agent.threads.get(threadId);
  if (!thread) return;

  ctx.logger.runtimeEvent(agent.agentId, threadId, event.tag, eventData(event));

  // Special cases handled directly
  if (event.tag === "cancel") {
    doCancel(ctx, agent, thread, actions);
    return;
  }
  if (event.tag === "canceled") {
    doCanceled(ctx, agent, thread, actions);
    return;
  }
  if (event.tag === "continue") {
    doContinueResponse(ctx, agent, thread, event, actions);
    return;
  }

  // All other events are dispatched to the PARENT thread
  if (thread.parent === null) {
    handleAtRoot(ctx, agent, thread, event, actions);
    return;
  }

  const parent = agent.threads.get(thread.parent);
  if (!parent || !parent.status) return;

  // If parent is CANCELING, only handle 'canceled'
  if (parent.status.tag === "CANCELING") {
    return; // non-canceled events are ignored during CANCELING
  }

  // If parent is REQUESTING, queue the event
  if (parent.status.tag === "REQUESTING") {
    parent.status.eventQueue.push(event);
    return;
  }

  // Parent is CALLING — dispatch based on CallingKind × EventType
  dispatchOnCallingKind(
    ctx,
    agent,
    parent,
    parent.status.kind,
    thread.threadId,
    event,
    actions,
  );
}

// ===========================================================================
// deliverEvent — deliver event directly to a thread (cross-agent)
//
// Used by Runtime to deliver events from child agents. Unlike fireEvent,
// this dispatches on the target thread's own CallingKind rather than
// going through the parent chain.
// ===========================================================================

export function deliverEvent(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  event: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  const thread = agent.threads.get(threadId);
  if (!thread || !thread.status) return;

  ctx.logger.runtimeEvent(
    agent.agentId,
    threadId,
    `deliver:${event.tag}`,
    eventData(event),
  );

  if (thread.status.tag === "REQUESTING") {
    thread.status.eventQueue.push(event);
    return;
  }

  if (thread.status.tag === "CANCELING") {
    if (event.tag === "canceled") {
      doCanceled(ctx, agent, thread, actions);
    }
    return;
  }

  if (thread.status.tag !== "CALLING") return;

  // Dispatch directly on this thread's CallingKind
  dispatchOnCallingKind(
    ctx,
    agent,
    thread,
    thread.status.kind,
    -1,
    event,
    actions,
  );
}

// ===========================================================================
// CallingKind × EventType dispatch matrix
// ===========================================================================

function dispatchOnCallingKind(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: CallingKind,
  childId: number,
  event: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  switch (event.tag) {
    case "completed":
      onCompleted(ctx, agent, parent, kind, event.value, childId, actions);
      break;
    case "returned":
      propagateGlobalExit(ctx, agent, parent, kind, childId,
        event, "AGENT", handleReturnedAtTarget, actions);
      break;
    case "continued":
      propagateGlobalExit(ctx, agent, parent, kind, childId,
        event, "HANDLE_BODY", handleContinuedAtTarget, actions);
      break;
    case "broken":
      propagateGlobalExit(ctx, agent, parent, kind, childId,
        event, "HANDLE_BODY", handleBrokenAtTarget, actions);
      break;
    case "for_continued":
      propagateGlobalExit(ctx, agent, parent, kind, childId,
        event, "FOR_BODY", handleForContinuedAtTarget, actions);
      break;
    case "for_broken":
      propagateGlobalExit(ctx, agent, parent, kind, childId,
        event, "FOR_BODY", handleForBrokenAtTarget, actions);
      break;
    case "requested":
      onRequested(ctx, agent, parent, kind, event, childId, actions);
      break;
    default:
      break;
  }
}

// ===========================================================================
// completed — NOT a global exit; each CallingKind has unique logic
// ===========================================================================

function onCompleted(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: CallingKind,
  value: Value,
  childId: number,
  actions: OutgoingAction[],
): void {
  switch (kind.tag) {
    case "DELEGATING":
      deleteThread(agent, childId);
      setVar(agent, parent.scopeId, kind.dst, value);
      resumeExecution(ctx, agent, parent, actions);
      break;

    case "AGENT":
      deleteThread(agent, childId);
      agent.scopes.delete(kind.childScopeId);
      setVar(agent, parent.scopeId, kind.dst, value);
      resumeExecution(ctx, agent, parent, actions);
      break;

    case "HANDLE_TARGET":
      deleteThread(agent, childId);
      transitionToHandleThen(
        ctx, agent, parent, kind,
        { tag: "completed", value }, value, actions,
      );
      break;

    case "HANDLE_BODY":
      // Handler completed normally → treat as continue (resume target)
      deleteThread(agent, childId);
      sendReply(kind.requesterInfo, value, actions);
      parent.status = {
        tag: "CALLING",
        kind: {
          tag: "HANDLE_TARGET",
          handleDefId: kind.handleDefId,
          childThreadId: kind.targetThreadId,
          dst: kind.dst,
          stateVars: kind.stateVars,
        },
      };
      fireEvent(ctx, agent, kind.targetThreadId, { tag: "continue", value }, actions);
      break;

    case "HANDLE_THEN": {
      deleteThread(agent, childId);
      const na = kind.nextAction;
      if (na.tag === "completed") {
        setVar(agent, parent.scopeId, kind.dst, value);
        resumeExecution(ctx, agent, parent, actions);
      } else {
        propagateUp(ctx, agent, parent, na, actions);
      }
      break;
    }

    case "FOR_BODY":
      deleteThread(agent, childId);
      advanceFor(ctx, agent, parent, kind, actions);
      break;

    case "FOR_THEN":
      deleteThread(agent, childId);
      setVar(agent, parent.scopeId, kind.dst, value);
      resumeExecution(ctx, agent, parent, actions);
      break;

    case "PARALLEL": {
      const idx = kind.branchThreadIds.indexOf(childId);
      if (idx !== -1) kind.results[idx] = value;
      deleteThread(agent, childId);
      if (kind.results.every((r) => r !== undefined)) {
        setVar(agent, parent.scopeId, kind.dst, kind.results as Value[]);
        resumeExecution(ctx, agent, parent, actions);
      }
      break;
    }
  }
}

// ===========================================================================
// Unified Global Exit — returned, continued, broken, for_continued, for_broken
//
// All share the same propagation structure: propagate up through intermediate
// CallingKinds until reaching the target, then execute target-specific logic.
// Intermediate layer handling is identical for ALL events (no branching).
// ===========================================================================

type GlobalExitTargetHandler = (
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: CallingKind,
  event: RuntimeEvent,
  actions: OutgoingAction[],
) => void;

function propagateGlobalExit(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: CallingKind,
  childId: number,
  event: RuntimeEvent,
  targetKind: CallingKind["tag"],
  handleAtTarget: GlobalExitTargetHandler,
  actions: OutgoingAction[],
): void {
  deleteThread(agent, childId);

  if (kind.tag === targetKind) {
    handleAtTarget(ctx, agent, parent, kind, event, actions);
    return;
  }

  // Intermediate layer — uniform for all events
  switch (kind.tag) {
    case "HANDLE_TARGET":
      transitionToHandleThen(
        ctx, agent, parent, kind, event,
        thenInputValue(event), actions,
      );
      break;
    case "HANDLE_BODY":
      cancelAndPropagate(ctx, agent, parent, kind.targetThreadId, event, actions);
      break;
    case "HANDLE_THEN":
      propagateUp(ctx, agent, parent, kind.nextAction, actions);
      break;
    case "PARALLEL":
      cancelOtherBranches(ctx, agent, parent, kind, childId, event, actions);
      break;
    case "AGENT":
    case "DELEGATING":
      ctx.logger.log("warn", `${event.tag} in ${kind.tag} — ignoring`);
      break;
    default: // FOR_BODY, FOR_THEN
      propagateUp(ctx, agent, parent, event, actions);
      break;
  }
}

/** Extract the then-clause input value from a global exit event */
function thenInputValue(event: RuntimeEvent): Value {
  switch (event.tag) {
    case "returned":
    case "broken":
    case "for_broken":
      return event.value;
    default:
      return null;
  }
}

// --- Target handlers ---

function handleReturnedAtTarget(
  ctx: DispatchContext, agent: AgentState, parent: ThreadState,
  kind: CallingKind, event: RuntimeEvent, actions: OutgoingAction[],
): void {
  const k = kind as AgentCallingKind;
  agent.scopes.delete(k.childScopeId);
  setVar(agent, parent.scopeId, k.dst, (event as { value: Value }).value);
  resumeExecution(ctx, agent, parent, actions);
}

function handleContinuedAtTarget(
  ctx: DispatchContext, agent: AgentState, parent: ThreadState,
  kind: CallingKind, event: RuntimeEvent, actions: OutgoingAction[],
): void {
  const k = kind as HandleBodyCallingKind;
  const ev = event as { tag: "continued"; value: Value; mutations: [number, number][] };
  for (const [sv, nv] of ev.mutations) {
    k.stateVars.set(sv, getVar(agent, parent.scopeId, nv));
  }
  sendReply(k.requesterInfo, ev.value, actions);
  parent.status = {
    tag: "CALLING",
    kind: {
      tag: "HANDLE_TARGET",
      handleDefId: k.handleDefId,
      childThreadId: k.targetThreadId,
      dst: k.dst,
      stateVars: k.stateVars,
    },
  };
  fireEvent(ctx, agent, k.targetThreadId, { tag: "continue", value: ev.value }, actions);
}

function handleBrokenAtTarget(
  ctx: DispatchContext, agent: AgentState, parent: ThreadState,
  kind: CallingKind, event: RuntimeEvent, actions: OutgoingAction[],
): void {
  const k = kind as HandleBodyCallingKind;
  const value = (event as { value: Value }).value;
  setVar(agent, parent.scopeId, k.dst, value);
  cancelAndPropagate(ctx, agent, parent, k.targetThreadId, { tag: "completed", value }, actions);
}

function handleForContinuedAtTarget(
  ctx: DispatchContext, agent: AgentState, parent: ThreadState,
  kind: CallingKind, event: RuntimeEvent, actions: OutgoingAction[],
): void {
  const k = kind as ForBodyCallingKind;
  const ev = event as { tag: "for_continued"; mutations: [number, number][] };
  for (const [sv, nv] of ev.mutations) {
    setVar(agent, parent.scopeId, sv, getVar(agent, parent.scopeId, nv));
  }
  advanceFor(ctx, agent, parent, k, actions);
}

function handleForBrokenAtTarget(
  ctx: DispatchContext, agent: AgentState, parent: ThreadState,
  kind: CallingKind, event: RuntimeEvent, actions: OutgoingAction[],
): void {
  const k = kind as ForBodyCallingKind;
  setVar(agent, parent.scopeId, k.dst, (event as { value: Value }).value);
  resumeExecution(ctx, agent, parent, actions);
}

// ===========================================================================
// requested — route to handler or pass upward
// ===========================================================================

function onRequested(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: CallingKind,
  event: RuntimeEvent & { tag: "requested" },
  childId: number,
  actions: OutgoingAction[],
): void {
  if (kind.tag === "HANDLE_TARGET") {
    // Check if this handle has a handler for this request
    const hdef = agent.module.handles.get(kind.handleDefId);
    if (hdef) {
      const match = hdef.reqCases.find(([rid]) => rid === event.reqDefId);
      if (match) {
        // Found handler — transition to HANDLE_BODY
        const handlerTid = match[1];

        // Copy state vars to parent's scope for handler access
        for (const [sv, val] of kind.stateVars) {
          setVar(agent, parent.scopeId, sv, val);
        }

        // Bind request args to handler params
        const handlerIr = agent.module.threads.get(handlerTid);
        const reqDef = agent.module.requests.get(event.reqDefId);
        if (handlerIr && reqDef) {
          for (let i = 0; i < reqDef.paramNames.length && i < handlerIr.params.length; i++) {
            const val = event.args[reqDef.paramNames[i]!];
            if (val !== undefined) setVar(agent, parent.scopeId, handlerIr.params[i]!, val);
          }
        }

        const requesterInfo: RequesterInfo = {
          escalationRef: event.escalationRef,
          escalationEndpoint: event.escalationEndpoint,
          internalThreadId: event.fromThreadId,
          internalRequestId: event.requestId,
        };

        parent.status = {
          tag: "CALLING",
          kind: {
            tag: "HANDLE_BODY",
            handleDefId: kind.handleDefId,
            targetThreadId: kind.childThreadId,
            handlerThreadId: handlerTid,
            dst: kind.dst,
            stateVars: kind.stateVars,
            requesterInfo,
          },
        };

        // Create and run handler thread
        const handlerThread = createThread(agent, handlerTid, parent.threadId);
        ctx.logger.runtimeEvent(agent.agentId, handlerThread.threadId, "thread:created",
          { parent: parent.threadId, blockId: handlerTid, reason: "handler_body", reqDefId: event.reqDefId });
        executeFromThread(ctx, agent, handlerThread.threadId, actions);
        return;
      }
    }
  }

  // No handler found (or not HANDLE_TARGET) — enter REQUESTING, pass upward
  parent.status = {
    tag: "REQUESTING",
    fromThread: childId,
    previousState: kind,
    eventQueue: [],
    escalationRef: null,
  };
  ctx.logger.runtimeEvent(agent.agentId, parent.threadId, "→REQUESTING",
    { fromThread: childId, reqDefId: event.reqDefId, prevKind: kind.tag });
  fireEvent(ctx, agent, parent.threadId, event, actions);
}

// ===========================================================================
// cancel — cancel this thread and all children
// ===========================================================================

function doCancel(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  actions: OutgoingAction[],
): void {
  // Null status means unstarted (e.g. parallel branch not yet executed)
  if (!thread.status) {
    deleteThread(agent, thread.threadId);
    if (thread.parent !== null) {
      fireEvent(ctx, agent, thread.parent, { tag: "canceled" }, actions);
    }
    return;
  }

  const status = thread.status;

  // Check for cross-agent children that need external termination.
  const callingKind =
    status.tag === "CALLING"
      ? status.kind
      : status.tag === "REQUESTING"
        ? status.previousState
        : null;

  // DELEGATING children need external termination
  if (callingKind?.tag === "DELEGATING") {
    actions.push({
      tag: "TerminateAgent",
      childAgentId: callingKind.delegationId,
    });
  }

  const children = getChildThreadIds(agent, thread.threadId);

  let externalCount = 0;
  if (callingKind?.tag === "DELEGATING") {
    externalCount = 1;
  }
  const totalPending = children.length + externalCount;

  if (totalPending === 0) {
    deleteThread(agent, thread.threadId);
    if (thread.parent !== null) {
      fireEvent(ctx, agent, thread.parent, { tag: "canceled" }, actions);
    }
    return;
  }

  thread.status = {
    tag: "CANCELING",
    nextAction: null,
    pendingCancelCount: totalPending,
  };

  for (const childId of children) {
    fireEvent(ctx, agent, childId, { tag: "cancel" }, actions);
  }
}

function doCanceled(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  actions: OutgoingAction[],
): void {
  if (!thread.status || thread.status.tag !== "CANCELING") return;

  thread.status.pendingCancelCount--;

  if (thread.status.pendingCancelCount <= 0) {
    const nextAction = thread.status.nextAction;
    deleteThread(agent, thread.threadId);

    if (nextAction) {
      if (thread.parent !== null) {
        fireEvent(ctx, agent, thread.parent, nextAction, actions);
      }
    } else {
      if (thread.parent !== null) {
        fireEvent(ctx, agent, thread.parent, { tag: "canceled" }, actions);
      }
    }
  }
}

// ===========================================================================
// continue — response to a request (REQUESTING thread resumes)
// ===========================================================================

function doContinueResponse(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  event: { tag: "continue"; value: Value },
  actions: OutgoingAction[],
): void {
  if (!thread.status || thread.status.tag !== "REQUESTING") {
    ctx.logger.log("warn", "continue on non-REQUESTING thread");
    return;
  }

  const { fromThread, previousState, eventQueue } = thread.status;

  if (fromThread === null) {
    // This thread itself issued IRequest or ICall(RaiseRequest) — store value and resume
    const irThread = agent.module.threads.get(thread.blockId);
    if (irThread) {
      const prevInstr = irThread.body[thread.pc - 1];
      if (prevInstr && (prevInstr.op === "Request" || prevInstr.op === "Call")) {
        setVar(agent, thread.scopeId, prevInstr.dst, event.value);
      }
    }
    thread.status = previousState ? { tag: "CALLING", kind: previousState } : null;
    resumeExecution(ctx, agent, thread, actions);
  } else {
    // Request came from a child thread — forward continue to it
    fireEvent(ctx, agent, fromThread, event, actions);

    // Drain event queue
    if (eventQueue.length > 0) {
      const next = eventQueue.shift()!;
      if (next.tag === "requested") {
        thread.status = {
          tag: "REQUESTING",
          fromThread: next.fromThreadId ?? fromThread,
          previousState,
          eventQueue,
          escalationRef: null,
        };
        fireEvent(ctx, agent, thread.threadId, next, actions);
      } else if (
        next.tag === "completed" ||
        next.tag === "returned" ||
        next.tag === "continued" ||
        next.tag === "broken" ||
        next.tag === "for_continued" ||
        next.tag === "for_broken"
      ) {
        if (previousState) {
          thread.status = { tag: "CALLING", kind: previousState };
          dispatchOnCallingKind(ctx, agent, thread, previousState, fromThread, next, actions);
        }
      } else {
        thread.status = previousState ? { tag: "CALLING", kind: previousState } : null;
      }
    } else {
      thread.status = previousState ? { tag: "CALLING", kind: previousState } : null;
    }
  }
}

// ===========================================================================
// executeFromThread — run IR instructions, handle StepResult
// ===========================================================================

export function executeFromThread(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  actions: OutgoingAction[],
): void {
  for (;;) {
    const result = executeThread(agent, threadId);
    if (!result) return;

    ctx.logger.runtimeEvent(agent.agentId, threadId, `step:${result.tag}`,
      result.tag === "call" ? { agentDefId: result.agentDefId } :
      result.tag === "request" ? { reqDefId: result.reqDefId } :
      result.tag === "handle" ? { handleId: result.handleId } :
      result.tag === "for" ? { forId: result.forId } :
      undefined);

    switch (result.tag) {
      // --- Terminal events: fire on this thread ---
      case "completed":
        fireEvent(ctx, agent, threadId, { tag: "completed", value: result.value }, actions);
        return;
      case "returned":
        fireEvent(ctx, agent, threadId, { tag: "returned", value: result.value }, actions);
        return;
      case "broken":
        fireEvent(ctx, agent, threadId, { tag: "broken", value: result.value }, actions);
        return;
      case "continued":
        fireEvent(ctx, agent, threadId,
          { tag: "continued", value: result.value, mutations: result.mutations }, actions);
        return;
      case "for_broken":
        fireEvent(ctx, agent, threadId, { tag: "for_broken", value: result.value }, actions);
        return;
      case "for_continued":
        fireEvent(ctx, agent, threadId, { tag: "for_continued", mutations: result.mutations }, actions);
        return;

      // --- Suspension: Handle ---
      case "handle":
        setupHandle(ctx, agent, threadId, result.dst, result.handleId, actions);
        return;

      // --- Suspension: For ---
      case "for":
        setupFor(ctx, agent, threadId, result.dst, result.forId, actions);
        return;

      // --- Suspension: Par ---
      case "par":
        setupPar(ctx, agent, threadId, result.dst, result.threads, actions);
        return;

      // --- Suspension: Call ---
      case "call": {
        const handled = ctx.callHandler(
          agent, threadId, result.dst, result.agentDefId, result.args, actions,
        );
        if (handled) {
          // Primitive — result stored, continue execution (loop again)
          break;
        }
        // Suspended (AGENT or DELEGATING) — stop
        return;
      }

      // --- Suspension: Request ---
      case "request":
        setupRequest(ctx, agent, threadId, result.dst, result.reqDefId, result.args, actions);
        return;
    }
  }
}

/** Resume executing IR instructions from current PC */
function resumeExecution(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  actions: OutgoingAction[],
): void {
  executeFromThread(ctx, agent, thread.threadId, actions);
}

// ===========================================================================
// Setup functions — prepare CallingKind for suspension instructions
// ===========================================================================

function setupHandle(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  dst: number,
  handleId: number,
  actions: OutgoingAction[],
): void {
  const hdef = agent.module.handles.get(handleId);
  if (!hdef) return;

  const thread = agent.threads.get(threadId);
  if (!thread) return;

  // Initialize state vars from thread's scope
  const stateVars = new Map<number, Value>();
  for (let i = 0; i < hdef.stateVars.length; i++) {
    stateVars.set(hdef.stateVars[i]!, getVar(agent, thread.scopeId, hdef.stateInits[i]!));
  }

  const bodyThread = createThread(agent, hdef.body, threadId);
  ctx.logger.runtimeEvent(agent.agentId, bodyThread.threadId, "thread:created",
    { parent: threadId, blockId: hdef.body, reason: "handle_scope", handleId });

  thread.status = {
    tag: "CALLING",
    kind: {
      tag: "HANDLE_TARGET",
      handleDefId: handleId,
      childThreadId: bodyThread.threadId,
      dst,
      stateVars,
    },
  };

  executeFromThread(ctx, agent, bodyThread.threadId, actions);
}

function setupFor(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  dst: number,
  forId: number,
  actions: OutgoingAction[],
): void {
  const fdef = agent.module.fors.get(forId);
  if (!fdef) return;

  const thread = agent.threads.get(threadId);
  if (!thread) return;
  const s = thread.scopeId;

  // Initialize state vars
  for (let i = 0; i < fdef.stateVars.length; i++) {
    setVar(agent, s, fdef.stateVars[i]!, getVar(agent, s, fdef.stateInits[i]!));
  }

  // Calculate min array length
  let minLen = Infinity;
  for (const arrVar of fdef.arrays) {
    const arr = getVar(agent, s, arrVar);
    minLen = Math.min(minLen, Array.isArray(arr) ? arr.length : 0);
  }
  if (!isFinite(minLen)) minLen = 0;

  if (minLen > 0) {
    // Set iter vars for first iteration
    for (let i = 0; i < fdef.iterVars.length; i++) {
      const arr = getVar(agent, s, fdef.arrays[i]!);
      if (Array.isArray(arr)) setVar(agent, s, fdef.iterVars[i]!, arr[0] ?? null);
    }

    const bodyThread = createThread(agent, fdef.body, threadId);
    ctx.logger.runtimeEvent(agent.agentId, bodyThread.threadId, "thread:created",
      { parent: threadId, blockId: fdef.body, reason: "for_body", forId });

    thread.status = {
      tag: "CALLING",
      kind: {
        tag: "FOR_BODY",
        forDefId: forId,
        childThreadId: bodyThread.threadId,
        currentIndex: 0,
        minLength: minLen,
        dst,
      },
    };

    executeFromThread(ctx, agent, bodyThread.threadId, actions);
  } else {
    // Empty loop — run then clause or set null
    if (fdef.then !== null) {
      const thenThread = createThread(agent, fdef.then, threadId);

      thread.status = {
        tag: "CALLING",
        kind: {
          tag: "FOR_THEN",
          forDefId: forId,
          thenThreadId: thenThread.threadId,
          dst,
        },
      };

      executeFromThread(ctx, agent, thenThread.threadId, actions);
    } else {
      setVar(agent, s, dst, null);
      resumeExecution(ctx, agent, thread, actions);
    }
  }
}

function setupPar(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  dst: number,
  tids: number[],
  actions: OutgoingAction[],
): void {
  const thread = agent.threads.get(threadId);
  if (!thread) return;

  const branchThreadIds: number[] = [];
  const branches: ThreadState[] = [];
  for (const tid of tids) {
    const branchThread = createThread(agent, tid, threadId);
    ctx.logger.runtimeEvent(agent.agentId, branchThread.threadId, "thread:created",
      { parent: threadId, blockId: tid, reason: "par_branch" });
    branchThreadIds.push(branchThread.threadId);
    branches.push(branchThread);
  }

  thread.status = {
    tag: "CALLING",
    kind: {
      tag: "PARALLEL",
      branchThreadIds,
      results: new Array(tids.length).fill(undefined),
      dst,
    },
  };

  for (const b of branches) {
    executeFromThread(ctx, agent, b.threadId, actions);
  }
}

function setupRequest(
  ctx: DispatchContext,
  agent: AgentState,
  threadId: number,
  dst: number,
  reqDefId: number,
  args: Record<string, Value>,
  actions: OutgoingAction[],
): void {
  const thread = agent.threads.get(threadId);
  if (!thread) return;

  const requestId = crypto.randomUUID();
  const previousState =
    thread.status?.tag === "CALLING" ? thread.status.kind : null;

  // Enter REQUESTING state
  thread.status = {
    tag: "REQUESTING",
    fromThread: null,
    previousState,
    eventQueue: [],
    escalationRef: null,
  };
  ctx.logger.runtimeEvent(agent.agentId, threadId, "request:issue",
    { reqDefId, requestId, prevKind: previousState?.tag ?? null });

  // Fire requested event (propagates up to find a handler)
  fireEvent(ctx, agent, threadId, {
    tag: "requested",
    reqDefId,
    args,
    requestId,
    fromThreadId: null,
    escalationRef: null,
    escalationEndpoint: null,
  }, actions);
}

// ===========================================================================
// Helpers
// ===========================================================================

/** Propagate event upward to parent thread */
function propagateUp(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  event: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  if (thread.parent !== null) {
    fireEvent(ctx, agent, thread.parent, event, actions);
  } else {
    handleAtRoot(ctx, agent, thread, event, actions);
  }
}

/** Handle event at root (no parent) */
function handleAtRoot(
  ctx: DispatchContext,
  agent: AgentState,
  thread: ThreadState,
  event: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  switch (event.tag) {
    case "completed":
    case "returned":
      actions.push({
        tag: "AgentCompleted",
        agentId: agent.agentId,
        value: event.value,
      });
      break;

    case "requested":
      ctx.rootRequestHandler(agent, thread.threadId, event, actions);
      break;

    default:
      ctx.logger.log("warn", `Unexpected event ${event.tag} at root thread`);
      break;
  }
}

/** Transition HANDLE_TARGET to HANDLE_THEN */
function transitionToHandleThen(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: HandleTargetCallingKind,
  nextAction: RuntimeEvent,
  thenInput: Value | null,
  actions: OutgoingAction[],
): void {
  const hdef = agent.module.handles.get(kind.handleDefId);
  if (hdef && hdef.then !== null) {
    const thenIr = agent.module.threads.get(hdef.then);
    if (thenIr && thenIr.params.length > 0 && thenInput !== null) {
      setVar(agent, parent.scopeId, thenIr.params[0]!, thenInput);
    }

    const thenThread = createThread(agent, hdef.then, parent.threadId);

    parent.status = {
      tag: "CALLING",
      kind: {
        tag: "HANDLE_THEN",
        handleDefId: kind.handleDefId,
        thenThreadId: thenThread.threadId,
        dst: kind.dst,
        stateVars: kind.stateVars,
        nextAction,
      },
    };

    executeFromThread(ctx, agent, thenThread.threadId, actions);
  } else {
    // No then clause — execute nextAction directly
    if (nextAction.tag === "completed") {
      setVar(
        agent, parent.scopeId, kind.dst,
        (nextAction as { tag: "completed"; value: Value }).value,
      );
      resumeExecution(ctx, agent, parent, actions);
    } else {
      propagateUp(ctx, agent, parent, nextAction, actions);
    }
  }
}

/** Advance for loop to next iteration or finish */
function advanceFor(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: ForBodyCallingKind,
  actions: OutgoingAction[],
): void {
  const nextIndex = kind.currentIndex + 1;
  const ps = parent.scopeId;
  if (nextIndex < kind.minLength) {
    const fdef = agent.module.fors.get(kind.forDefId);
    if (fdef) {
      for (let i = 0; i < fdef.iterVars.length; i++) {
        const arr = getVar(agent, ps, fdef.arrays[i]!);
        if (Array.isArray(arr)) {
          setVar(agent, ps, fdef.iterVars[i]!, arr[nextIndex] ?? null);
        }
      }

      const bodyThread = createThread(agent, fdef.body, parent.threadId);

      parent.status = {
        tag: "CALLING",
        kind: { ...kind, currentIndex: nextIndex, childThreadId: bodyThread.threadId },
      };

      executeFromThread(ctx, agent, bodyThread.threadId, actions);
    }
  } else {
    const fdef = agent.module.fors.get(kind.forDefId);
    if (fdef && fdef.then !== null) {
      const thenThread = createThread(agent, fdef.then, parent.threadId);

      parent.status = {
        tag: "CALLING",
        kind: {
          tag: "FOR_THEN",
          forDefId: kind.forDefId,
          thenThreadId: thenThread.threadId,
          dst: kind.dst,
        },
      };

      executeFromThread(ctx, agent, thenThread.threadId, actions);
    } else {
      setVar(agent, ps, kind.dst, null);
      resumeExecution(ctx, agent, parent, actions);
    }
  }
}

/** Cancel a specific child thread, then propagate event after all canceled */
function cancelAndPropagate(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  childToCancel: number,
  afterEvent: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  parent.status = {
    tag: "CANCELING",
    nextAction: afterEvent,
    pendingCancelCount: 1,
  };
  fireEvent(ctx, agent, childToCancel, { tag: "cancel" }, actions);
}

/** Cancel all par branches except the one that triggered, then propagate */
function cancelOtherBranches(
  ctx: DispatchContext,
  agent: AgentState,
  parent: ThreadState,
  kind: ParallelCallingKind,
  triggeringChildId: number,
  afterEvent: RuntimeEvent,
  actions: OutgoingAction[],
): void {
  const others = kind.branchThreadIds.filter(
    (id) => id !== triggeringChildId && agent.threads.has(id),
  );

  if (others.length === 0) {
    propagateUp(ctx, agent, parent, afterEvent, actions);
    return;
  }

  parent.status = {
    tag: "CANCELING",
    nextAction: afterEvent,
    pendingCancelCount: others.length,
  };

  for (const otherId of others) {
    fireEvent(ctx, agent, otherId, { tag: "cancel" }, actions);
  }
}

/** Send escalate_ack or internal reply */
function sendReply(
  requester: RequesterInfo,
  value: Value,
  actions: OutgoingAction[],
): void {
  if (requester.escalationRef && requester.escalationEndpoint) {
    actions.push({
      tag: "ProtocolEscalateAck",
      escalationRef: requester.escalationRef,
      escalationEndpoint: requester.escalationEndpoint,
      output: value as JsonValue,
    });
  }
}

// ===========================================================================
// Logging helper — extract key data from a RuntimeEvent for structured output
// ===========================================================================

function eventData(event: RuntimeEvent): Record<string, unknown> | undefined {
  switch (event.tag) {
    case "completed":
    case "returned":
    case "broken":
    case "for_broken":
    case "continue":
      return { value: summarizeValue(event.value) };
    case "continued":
      return {
        value: summarizeValue(event.value),
        mutations: event.mutations.length,
      };
    case "for_continued":
      return { mutations: event.mutations.length };
    case "requested":
      return {
        reqDefId: event.reqDefId,
        requestId: event.requestId?.slice(0, 8),
      };
    case "call":
      return { blockId: event.blockId };
    default:
      return undefined;
  }
}

function summarizeValue(v: unknown): unknown {
  if (v === null || v === undefined) return null;
  if (typeof v === "string") return v.length > 40 ? v.slice(0, 40) + "..." : v;
  if (typeof v !== "object") return v;
  if (Array.isArray(v)) return `[${v.length} items]`;
  return "{...}";
}
