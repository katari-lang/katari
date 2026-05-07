import type { BlockId, ContKind, HandleBlock, IRModule, ReqId, VarId } from "../../ir/types.js";
import type { AskId, ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import { getValueFromScope, setValueInScope } from "../scope.js";
import type { Value } from "../value.js";
import {
  ChildThread,
  extendBoundaries,
  resolveBlockPayload,
  type CallId,
  type ChildThreadInit,
  type SerializedChildThreadCommon,
  type Thread,
} from "./types.js";
import type { RequestThread } from "./request.js";

/**
 * BlockHandle: an algebraic-effect handler scope.
 *
 * Children are one of three roles, tracked via `childRoles`:
 *   - main  (callId = 0) — the body the handler block guards.
 *   - handlerBody (callId ≥ 1) — a handler body spawned in response
 *     to an `ask`. Bound to a specific `(asker, askId, reqId)`.
 *   - thenClause (callId ≥ 1) — the optional `then(r) { ... }` clause
 *     run after the main target completes successfully.
 *
 * Two state-machines guide the lifecycle:
 *
 *   1. Sequential queue. When `block.parallel === false`, only one
 *      handler-body / thenClause runs at a time. New asks and the
 *      then-clause activation are queued in `pendingActions` and dequeued
 *      as the currently-running child finishes.
 *
 *   2. Per-child post-cancel actions. When `next` resumes a handler,
 *      we cancel only that one handler-body without putting the whole
 *      HandleThread into "cancelling" state. After the cancelled child
 *      acks, we look up `postCancelActions[callId]` and execute it
 *      (typically: emit `askComplete` to the asker, then pop the queue).
 *
 * `break` and "thenClause done" reuse the existing return-event
 * machinery: HandleThread enters status="cancelling" with `pendingReturn`
 * set, all children are cancelled, and finishCancelling emits `done` to
 * the parent.
 *
 * Boundary registration: HandleThread is the boundary for `break`
 * (`exitKindBreak`) and `next` (`contKindNext`); the constructor installs
 * `this` into both slots.
 */
export class HandleThread extends ChildThread {
  readonly block: HandleBlock;
  /** IR id of the BlockHandle backing this thread. See UserThread.blockId. */
  readonly blockId: BlockId;
  private readonly childRoles: Map<CallId, ChildRole> = new Map();
  private readonly pendingActions: PendingAction[] = [];
  private readonly postCancelActions: Map<CallId, PostCancelAction> = new Map();
  /** CallId allocator for non-main children. main is reserved as 0. */
  private nextCallId: CallId = 1;

  /**
   * Sequential-mode gate: true while a handler-body or thenClause is in
   * flight, derived from `childRoles`. New asks queue while busy; parallel
   * mode bypasses the gate entirely (returns false unconditionally).
   *
   * **Why a getter, not a stored field**: previous revisions kept `busy`
   * as a serialized field. A snapshot taken between
   * `pendingActions.shift()` and the spawn of the next action could pin
   * `busy = true` with `pendingActions` empty and no live handlerBody —
   * after restore, every new ask would queue forever (deadlock). Deriving
   * `busy` from the live `childRoles` map makes round-trip impossible to
   * desynchronize: re-entry to onAsk after restore re-checks the same
   * source of truth the live code uses.
   */
  private get busy(): boolean {
    if (this.block.parallel) return false;
    for (const role of this.childRoles.values()) {
      if (role.kind === "handlerBody" || role.kind === "thenClause") {
        return true;
      }
    }
    return false;
  }

  constructor(
    machine: MachineState,
    init: ChildThreadInit,
    block: HandleBlock,
    blockId: BlockId,
  ) {
    super(init);
    this.block = block;
    this.blockId = blockId;

    // Initialize state variables in the handle scope from the caller scope.
    // The caller scope is reachable via the parent chain (init.scopeId is
    // a fresh scope under the caller's scope, per callInline mechanics).
    for (const [bodyVar, initVar] of block.stateInits) {
      const initValue = getValueFromScope(machine, init.scopeId, initVar);
      setValueInScope(machine, init.scopeId, bodyVar, initValue);
    }

    // Install self as the boundary for break / next.
    this.boundaries = extendBoundaries(this.boundaries, {
      exitKindBreak: this,
      contKindNext: this,
    });
  }

  override onCall(machine: MachineState): void {
    // Spawn the main target. Augment handlers with this handle's own
    // overrides so the body's requests are caught here. handler-body and
    // thenClause spawns NEVER add this augmentation — they see the outer
    // handlers (algebraic effect semantics).
    this.childRoles.set(MAIN_CALL_ID, { kind: "main" });
    const augmented = new Map(this.handlers);
    for (const handler of this.block.handlers) {
      augmented.set(handler.request, this);
    }
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId: MAIN_CALL_ID,
      blockId: this.block.body,
      args: {},
      scopeId: this.scopeId,
      handlersOverride: augmented,
    });
  }

  // ─── ask handling ───────────────────────────────────────────────────────

  override onAsk(
    machine: MachineState,
    asker: Thread,
    askId: AskId,
    reqId: ReqId,
    args: Record<string, Value>,
  ): void {
    const action: PendingAction = { kind: "ask", reqId, args, asker, askId };
    if (this.block.parallel || !this.busy) {
      this.runPendingAction(machine, action);
    } else {
      this.pendingActions.push(action);
    }
  }

  /**
   * Spawn the child for `action`. In sequential mode this is gated by
   * `busy === false`; in parallel mode it can run any number of times
   * concurrently.
   */
  private runPendingAction(machine: MachineState, action: PendingAction): void {
    switch (action.kind) {
      case "ask":
        this.spawnHandlerBody(machine, action);
        return;
      case "thenClause":
        this.spawnThenClause(machine, action.mainResultValue);
        return;
    }
  }

  private spawnHandlerBody(
    machine: MachineState,
    action: { reqId: ReqId; args: Record<string, Value>; asker: Thread; askId: AskId },
  ): void {
    const handler = this.block.handlers.find((h) => h.request === action.reqId);
    if (handler === undefined) {
      throw new Error(
        `HandleThread.spawnHandlerBody: no handler for reqId ${action.reqId} in this handle block`,
      );
    }
    const callId = this.nextCallId++ as CallId;
    this.childRoles.set(callId, {
      kind: "handlerBody",
      reqId: action.reqId,
      askId: action.askId,
      asker: action.asker,
    });
    // `busy` becomes true automatically: it's derived from childRoles and we
    // just inserted a "handlerBody" role above.
    // No handlersOverride — the body inherits this HandleThread's handlers,
    // which deliberately do NOT include this handle's own overrides.
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId,
      blockId: handler.handlerBody,
      args: action.args,
      scopeId: this.scopeId,
    });
  }

  private spawnThenClause(machine: MachineState, mainResultValue: Value): void {
    if (this.block.thenBlock === undefined) {
      // No `then` clause: the main result is the handle's value directly.
      // Reuse the return-mechanism finish path: pendingReturn + cancel of
      // remaining children, then finishCancelling emits done.
      this.enterCancellingForResult(machine, mainResultValue);
      return;
    }
    const callId = this.nextCallId++ as CallId;
    this.childRoles.set(callId, { kind: "thenClause", mainResultValue });
    // `busy` becomes true automatically via childRoles.
    machine.queue.push({
      kind: "callInline",
      parent: this,
      callId,
      blockId: this.block.thenBlock,
      args: { value: mainResultValue },
      scopeId: this.scopeId,
    });
  }

  // ─── cont (next) handling ───────────────────────────────────────────────

  override onCont(
    machine: MachineState,
    source: Thread,
    _contKind: ContKind,
    value: Value,
    modifiers: ReadonlyMap<VarId, Value>,
  ): void {
    // Apply state-var modifiers to the handle scope.
    for (const [targetVar, newValue] of modifiers) {
      setValueInScope(machine, this.scopeId, targetVar, newValue);
    }

    // Find which immediate child of `this` is the ancestor of `source`.
    const childCallId = findImmediateChildCallId(this, source);
    const role = this.childRoles.get(childCallId);
    if (role === undefined || role.kind !== "handlerBody") {
      throw new Error(
        `HandleThread.onCont: source's owning child is not a handlerBody (callId=${childCallId})`,
      );
    }

    // Schedule askComplete to fire after the handler body has cancelled,
    // then send the cancel.
    this.postCancelActions.set(childCallId, {
      kind: "askComplete",
      asker: role.asker,
      askId: role.askId,
      value,
    });
    const childThread = this.children.get(childCallId);
    if (childThread === undefined) {
      throw new Error(
        `HandleThread.onCont: no live child at callId ${childCallId}`,
      );
    }
    machine.queue.push({ kind: "cancel", target: childThread });
  }

  // ─── done handling ──────────────────────────────────────────────────────

  protected override onChildDone(machine: MachineState, callId: CallId, value: Value): void {
    const role = this.childRoles.get(callId);
    if (role === undefined) {
      throw new Error(`HandleThread.onChildDone: no role for callId ${callId}`);
    }
    this.childRoles.delete(callId);

    switch (role.kind) {
      case "main": {
        // Enqueue thenClause execution. In sequential mode if a handler is
        // still running we wait; otherwise dispatch immediately.
        const action: PendingAction = { kind: "thenClause", mainResultValue: value };
        if (this.block.parallel || !this.busy) {
          this.runPendingAction(machine, action);
        } else {
          this.pendingActions.push(action);
        }
        return;
      }
      case "handlerBody":
        throw new Error(
          "HandleThread.onChildDone: handler body finished without break/next (must end with one of them)",
        );
      case "thenClause":
        // thenClause finished. Cancel all remaining children, then emit
        // `done` to our parent with the thenClause's result.
        this.enterCancellingForResult(machine, value);
        return;
    }
  }

  // ─── cancelAck handling (post-cancel followups) ─────────────────────────

  protected override onChildCancelAck(machine: MachineState, callId: CallId): void {
    this.childRoles.delete(callId);
    const action = this.postCancelActions.get(callId);
    if (action === undefined) {
      throw new Error(
        `HandleThread.onChildCancelAck: no postCancelAction for callId ${callId}`,
      );
    }
    this.postCancelActions.delete(callId);
    switch (action.kind) {
      case "askComplete": {
        // RequestThread is the only kind currently registered as an asker.
        machine.queue.push({
          kind: "askComplete",
          target: action.asker as RequestThread,
          askId: action.askId,
          value: action.value,
        });
        // `busy` becomes false automatically: childRoles.delete(callId) above
        // removed the only handlerBody role this gate was waiting on. Now
        // dispatch the next pending action if any.
        const next = this.pendingActions.shift();
        if (next !== undefined) {
          this.runPendingAction(machine, next);
        }
        return;
      }
    }
  }

  // ─── helpers ────────────────────────────────────────────────────────────

  /**
   * Mark this handle as "cancelling, will emit done with `value`". Used by
   * thenClause-done. Cancels any remaining children; finishCancelling
   * emits the done once they are all gone.
   */
  private enterCancellingForResult(machine: MachineState, value: Value): void {
    this.status = "cancelling";
    this.pendingReturn = value;
    if (this.children.size === 0) {
      this.finishCancelling(machine);
      return;
    }
    for (const child of this.children.values()) {
      machine.queue.push({ kind: "cancel", target: child });
    }
  }

  // ─── Snapshot ──────────────────────────────────────────────────────────

  override serialize(): SerializedHandleThread {
    return {
      kind: "handle",
      ...this.serializeChildCommon(),
      blockId: this.blockId,
      childRoles: [...this.childRoles.entries()].map(([callId, role]) => [
        callId,
        serializeChildRole(role),
      ]),
      pendingActions: this.pendingActions.map(serializePendingAction),
      postCancelActions: [...this.postCancelActions.entries()].map(
        ([callId, action]) => [callId, serializePostCancelAction(action)],
      ),
      nextCallId: this.nextCallId,
      // busy is intentionally omitted — it's derived from `childRoles` at
      // read time; persisting it risks deadlock after a snapshot taken in
      // the gap between pendingActions.shift() and the next spawn.
    };
  }

  static restoreSkeleton(
    serialized: SerializedHandleThread,
    irModule: IRModule,
  ): HandleThread {
    const thread = Object.create(HandleThread.prototype) as HandleThread;
    thread.applySnapshotChildCommon(serialized);
    const writable = thread as unknown as {
      block: HandleBlock;
      blockId: BlockId;
      childRoles: Map<CallId, ChildRole>;
      pendingActions: PendingAction[];
      postCancelActions: Map<CallId, PostCancelAction>;
      nextCallId: CallId;
    };
    const block = resolveBlockPayload(irModule, serialized.blockId, "blockHandle");
    writable.block = block.handleBlock;
    writable.blockId = serialized.blockId;
    writable.childRoles = new Map(); // filled by link
    writable.pendingActions = []; // filled by link
    writable.postCancelActions = new Map(); // filled by link
    writable.nextCallId = serialized.nextCallId;
    return thread;
  }

  link(
    serialized: SerializedHandleThread,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkChildCommon(serialized, threadsById);
    const writable = this as unknown as {
      childRoles: Map<CallId, ChildRole>;
      pendingActions: PendingAction[];
      postCancelActions: Map<CallId, PostCancelAction>;
    };
    writable.childRoles = new Map(
      serialized.childRoles.map(([callId, role]) => [
        callId,
        deserializeChildRole(role, threadsById),
      ]),
    );
    writable.pendingActions = serialized.pendingActions.map((a) =>
      deserializePendingAction(a, threadsById),
    );
    writable.postCancelActions = new Map(
      serialized.postCancelActions.map(([callId, action]) => [
        callId,
        deserializePostCancelAction(action, threadsById),
      ]),
    );
  }
}

const MAIN_CALL_ID = 0 as CallId;

// ─── Internal types ────────────────────────────────────────────────────────

export type ChildRole =
  | { kind: "main" }
  | { kind: "handlerBody"; reqId: ReqId; askId: AskId; asker: Thread }
  | { kind: "thenClause"; mainResultValue: Value };

export type PendingAction =
  | { kind: "ask"; reqId: ReqId; args: Record<string, Value>; asker: Thread; askId: AskId }
  | { kind: "thenClause"; mainResultValue: Value };

export type PostCancelAction =
  | { kind: "askComplete"; asker: Thread; askId: AskId; value: Value };

// ─── Snapshot types & helpers ───────────────────────────────────────────────

import { resolveThread } from "./types.js";

export type SerializedChildRole =
  | { kind: "main" }
  | { kind: "handlerBody"; reqId: ReqId; askId: AskId; askerId: ThreadId }
  | { kind: "thenClause"; mainResultValue: Value };

export type SerializedPendingAction =
  | {
      kind: "ask";
      reqId: ReqId;
      args: Record<string, Value>;
      askerId: ThreadId;
      askId: AskId;
    }
  | { kind: "thenClause"; mainResultValue: Value };

export type SerializedPostCancelAction = {
  kind: "askComplete";
  askerId: ThreadId;
  askId: AskId;
  value: Value;
};

export type SerializedHandleThread = SerializedChildThreadCommon & {
  kind: "handle";
  blockId: BlockId;
  childRoles: [CallId, SerializedChildRole][];
  pendingActions: SerializedPendingAction[];
  postCancelActions: [CallId, SerializedPostCancelAction][];
  nextCallId: CallId;
  /**
   * Optional / legacy. The runtime no longer persists `busy` (see the
   * getter on HandleThread for the rationale); older snapshots that still
   * include the field are accepted and ignored on restore.
   */
  busy?: boolean;
};

function serializeChildRole(role: ChildRole): SerializedChildRole {
  switch (role.kind) {
    case "main":
      return { kind: "main" };
    case "handlerBody":
      return {
        kind: "handlerBody",
        reqId: role.reqId,
        askId: role.askId,
        askerId: role.asker.id,
      };
    case "thenClause":
      return { kind: "thenClause", mainResultValue: role.mainResultValue };
  }
}

function deserializeChildRole(
  role: SerializedChildRole,
  threadsById: ReadonlyMap<ThreadId, Thread>,
): ChildRole {
  switch (role.kind) {
    case "main":
      return { kind: "main" };
    case "handlerBody":
      return {
        kind: "handlerBody",
        reqId: role.reqId,
        askId: role.askId,
        asker: resolveThread(threadsById, role.askerId),
      };
    case "thenClause":
      return { kind: "thenClause", mainResultValue: role.mainResultValue };
  }
}

function serializePendingAction(
  action: PendingAction,
): SerializedPendingAction {
  switch (action.kind) {
    case "ask":
      return {
        kind: "ask",
        reqId: action.reqId,
        args: action.args,
        askerId: action.asker.id,
        askId: action.askId,
      };
    case "thenClause":
      return { kind: "thenClause", mainResultValue: action.mainResultValue };
  }
}

function deserializePendingAction(
  action: SerializedPendingAction,
  threadsById: ReadonlyMap<ThreadId, Thread>,
): PendingAction {
  switch (action.kind) {
    case "ask":
      return {
        kind: "ask",
        reqId: action.reqId,
        args: action.args,
        asker: resolveThread(threadsById, action.askerId),
        askId: action.askId,
      };
    case "thenClause":
      return { kind: "thenClause", mainResultValue: action.mainResultValue };
  }
}

function serializePostCancelAction(
  action: PostCancelAction,
): SerializedPostCancelAction {
  return {
    kind: "askComplete",
    askerId: action.asker.id,
    askId: action.askId,
    value: action.value,
  };
}

function deserializePostCancelAction(
  action: SerializedPostCancelAction,
  threadsById: ReadonlyMap<ThreadId, Thread>,
): PostCancelAction {
  return {
    kind: "askComplete",
    asker: resolveThread(threadsById, action.askerId),
    askId: action.askId,
    value: action.value,
  };
}

// ─── Module-level helpers ───────────────────────────────────────────────────

/**
 * Walk `source.parent` chain until we hit a thread whose parent is `handle`.
 * That thread is the immediate child of `handle` on the path from `source`.
 */
function findImmediateChildCallId(handle: HandleThread, source: Thread): CallId {
  let cur: Thread | null = source;
  while (cur !== null) {
    if (cur.parent === handle && cur.parentCallId !== null) {
      return cur.parentCallId;
    }
    cur = cur.parent;
  }
  throw new Error(
    "findImmediateChildCallId: source is not a descendant of handle",
  );
}
