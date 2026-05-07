import type {
  BlockId,
  ContKind,
  ExitKind,
  ReqId,
  VarId,
} from "../../ir/types.js";
import type { AskId, ScopeId, ThreadId } from "../id.js";
import type { MachineState } from "../machine.js";
import type { Value } from "../value.js";

import type { ForThread } from "./for.js";
import type { HandleThread } from "./handle.js";
import type { RequestThread } from "./request.js";
import type { UserThread } from "./user.js";

// ─── CallId ─────────────────────────────────────────────────────────────────

/**
 * Identifies a specific child call within a parent thread.
 * Each thread variant uses natural indices (element index, pc, etc.).
 */
export type CallId = number;

// ─── Boundaries ─────────────────────────────────────────────────────────────

/**
 * Direct dispatch targets for the five global-exit operations.
 *
 * Each thread carries this map and exit / cont statements look up their
 * boundary thread directly via `thread.boundaries[exitKind | contKind]`.
 * Inherited from parent by reference at thread creation. Boundary-type
 * subclasses (UserThread for agents, ForThread, HandleThread) overwrite
 * the relevant slot(s) by *replacing* their `boundaries` field with a new
 * frozen object derived via {@link extendBoundaries} — the parent's map
 * is never mutated.
 *
 * Frozen at construction so attempts to mutate the inherited map (which
 * would silently corrupt the parent's view as well) fail loudly.
 */
export type Boundaries = Readonly<{
  /**
   * Return boundary. Always a UserThread whose underlying block has
   * `kind === "blockKindAgent"` — that's the only construct that catches
   * `return`.
   */
  exitKindReturn: UserThread | null;
  /** for_break boundary — always the for thread itself. */
  exitKindForBreak: ForThread | null;
  /** break boundary — always the handle thread itself. */
  exitKindBreak: HandleThread | null;
  /** for_next boundary — always the for thread itself. */
  contKindForNext: ForThread | null;
  /** next boundary — always the handle thread itself. */
  contKindNext: HandleThread | null;
}>;

/** Initial boundaries with every key set to null. Used for root (APIThread). */
export const EMPTY_BOUNDARIES: Boundaries = Object.freeze({
  exitKindReturn: null,
  exitKindForBreak: null,
  exitKindBreak: null,
  contKindForNext: null,
  contKindNext: null,
});

/**
 * Build a new (frozen) Boundaries by overlaying `overrides` on top of
 * `parent`. The parent map is left untouched; the result is the *only*
 * sanctioned way for a boundary thread (UserThread for agents, ForThread,
 * HandleThread) to install itself into one or more slots without leaking
 * mutations back to its parent.
 */
export function extendBoundaries(
  parent: Boundaries,
  overrides: Partial<Boundaries>,
): Boundaries {
  return Object.freeze({ ...parent, ...overrides });
}

/** Key used to address a boundary slot. ExitKind ∪ ContKind. */
export type BoundaryKey = ExitKind | ContKind;

/**
 * Mutable view of a class instance, produced by stripping `readonly`
 * from every field. Used exclusively in snapshot-restoration code paths,
 * where each `Thread` subclass needs to assign through its declared
 * readonly fields after the prototype has been attached via
 * `Object.create`. Constructors handle that automatically; here we are
 * outside any constructor, so we narrow the unsafe `as unknown as ...`
 * idiom to a single named cast that documents the intent.
 *
 * Note: `InternalMutable<T>` only exposes `keyof T` — TypeScript's `keyof`
 * does not include private fields, so this cast cannot be used to write
 * through `private` slots. Variant-specific restoreSkeleton paths still
 * use a smaller anonymous shape for those private fields.
 */
export type InternalMutable<T> = { -readonly [K in keyof T]: T[K] };

// ─── Init payloads ──────────────────────────────────────────────────────────

/** Common construction data for any thread. */
export type ThreadInit = {
  id: ThreadId;
  scopeId: ScopeId;
  /**
   * Active handler-owning HandleThreads, keyed by the request id they
   * service. Only HandleThread can install entries (via `block.handlers`
   * spawn paths), so the value type is narrowed accordingly — RequestThread
   * et al. can dispatch to `handlers.get(reqId)` without casting.
   */
  handlers: ReadonlyMap<ReqId, HandleThread>;
  boundaries: Boundaries;
};

/** Construction data for a non-root thread. */
export type ChildThreadInit = ThreadInit & {
  parent: Thread;
  parentCallId: CallId;
};

/**
 * Backwards-compatible alias used by per-variant create paths.
 * Every concrete child thread is constructed with this shape.
 */
export type CreateThreadInit = ChildThreadInit;

// ─── Snapshot — common types & helpers ──────────────────────────────────────

/** Boundaries serialized as ThreadIds (or null). */
export type SerializedBoundaries = {
  exitKindReturn: ThreadId | null;
  exitKindForBreak: ThreadId | null;
  exitKindBreak: ThreadId | null;
  contKindForNext: ThreadId | null;
  contKindNext: ThreadId | null;
};

/** Per-Thread fields shared by every variant in snapshot form. */
export type SerializedThreadCommon = {
  id: ThreadId;
  scopeId: ScopeId;
  status: "running" | "cancelling";
  children: [CallId, ThreadId][];
  handlers: [ReqId, ThreadId][];
  boundaries: SerializedBoundaries;
  pendingReturn?: Value;
};

/** Adds parent ref + parentCallId for non-root threads. */
export type SerializedChildThreadCommon = SerializedThreadCommon & {
  parent: ThreadId;
  parentCallId: CallId;
};

export function serializeBoundaries(b: Boundaries): SerializedBoundaries {
  return {
    exitKindReturn: b.exitKindReturn?.id ?? null,
    exitKindForBreak: b.exitKindForBreak?.id ?? null,
    exitKindBreak: b.exitKindBreak?.id ?? null,
    contKindForNext: b.contKindForNext?.id ?? null,
    contKindNext: b.contKindNext?.id ?? null,
  };
}

export function deserializeBoundaries(
  s: SerializedBoundaries,
  threadsById: ReadonlyMap<ThreadId, Thread>,
): Boundaries {
  // Each slot's runtime type is narrower than `Thread` (UserThread for
  // exitKindReturn, ForThread for exitKindFor*, HandleThread for the
  // remainder), but the snapshot only stores ThreadIds and the resolver
  // only knows about the generic Thread base. The serializer wrote slots
  // from a properly-narrowed Boundaries; we trust the round-trip and cast
  // back to the narrowed type. If the snapshot was hand-crafted with the
  // wrong kind in a slot, downstream uses (statementExit/statementCont
  // dispatch sites) will fail loudly.
  const lookup = <T extends Thread>(id: ThreadId | null): T | null =>
    id === null ? null : (resolveThread(threadsById, id) as T);
  return Object.freeze({
    exitKindReturn: lookup<UserThread>(s.exitKindReturn),
    exitKindForBreak: lookup<ForThread>(s.exitKindForBreak),
    exitKindBreak: lookup<HandleThread>(s.exitKindBreak),
    contKindForNext: lookup<ForThread>(s.contKindForNext),
    contKindNext: lookup<HandleThread>(s.contKindNext),
  });
}

export function resolveThread(
  threadsById: ReadonlyMap<ThreadId, Thread>,
  id: ThreadId,
): Thread {
  const thread = threadsById.get(id);
  if (thread === undefined) {
    throw new Error(`snapshot: thread ${id} not found while linking refs`);
  }
  return thread;
}

/**
 * Look up a block payload from the IR module by id and assert its kind.
 * Used by the per-variant `restoreSkeleton` paths so they don't have to
 * carry the full block payload through the snapshot — only its blockId is
 * persisted, and the IR (which is supplied separately to the
 * deserializer) is the source of truth for the block's contents.
 */
export function resolveBlockPayload<K extends import("../../ir/types.js").Block["kind"]>(
  irModule: import("../../ir/types.js").IRModule,
  blockId: import("../../ir/types.js").BlockId,
  expectedKind: K,
): Extract<import("../../ir/types.js").Block, { kind: K }> {
  const block = irModule.blocks[blockId];
  if (block === undefined) {
    throw new Error(
      `snapshot: blockId ${blockId} referenced by thread skeleton not found in IR module`,
    );
  }
  if (block.kind !== expectedKind) {
    throw new Error(
      `snapshot: expected blockId ${blockId} to be of kind ${expectedKind}, got ${block.kind}`,
    );
  }
  return block as Extract<import("../../ir/types.js").Block, { kind: K }>;
}

/**
 * Wide return type for `Thread.serialize`. Concrete variants return their
 * own narrower shape (`SerializedAPIThread`, `SerializedUserThread`, ...);
 * the snapshot orchestrator (`runtime/snapshot.ts`) carries the proper
 * discriminated union and re-narrows by `kind` on restore.
 */
export type SerializedThreadAny = SerializedThreadCommon & {
  kind: string;
};

// ─── Thread (abstract base) ─────────────────────────────────────────────────

/**
 * Base for every thread variant. Owns the lifecycle algorithm and the
 * mutable state (`children`, `status`, `pendingReturn`, `boundaries`).
 *
 * The runner only sees the public template methods (`onChildDoneFromRunner`,
 * `onCancelReceived`, ...) and the abstract entry point (`onCall`). All
 * dispatch is virtual; no kind-based switching outside the IR factory.
 *
 * Subclasses override hooks (`onChildDone`, `onChildCancelAck`,
 * `beginCancel`, `onAsk`, `onAskComplete`, `onCont`, ...). Defaults throw
 * so accidental misrouting is loud rather than silent.
 */
export abstract class Thread {
  abstract readonly parent: Thread | null;
  abstract readonly parentCallId: CallId | null;

  readonly id: ThreadId;
  readonly scopeId: ScopeId;
  readonly handlers: ReadonlyMap<ReqId, HandleThread>;

  protected children: Map<CallId, Thread>;
  protected status: "running" | "cancelling";
  protected boundaries: Boundaries;
  protected pendingReturn?: Value;

  constructor(init: ThreadInit) {
    this.id = init.id;
    this.scopeId = init.scopeId;
    this.handlers = init.handlers;
    this.children = new Map();
    this.status = "running";
    this.boundaries = init.boundaries;
  }

  // ─── Read-only accessors used outside the class ─────────────────────────

  /** Snapshot of the active children map. Used for GC, debug, scope tracing. */
  get childThreads(): ReadonlyMap<CallId, Thread> {
    return this.children;
  }

  /** Status snapshot. Used for FFI ack routing (external thread). */
  get statusValue(): "running" | "cancelling" {
    return this.status;
  }

  /**
   * Boundary map snapshot. Used by the runner to inherit boundaries to a
   * freshly-created child. The returned map must be treated as immutable.
   */
  get boundariesView(): Boundaries {
    return this.boundaries;
  }

  // ─── Template methods (final — do not override) ─────────────────────────

  /**
   * Called by runner on `done` event whose `parent` is this thread.
   * Removes the child from book-keeping, then either advances cancellation
   * or hands off to the per-variant `onChildDone` hook.
   */
  onChildDoneFromRunner(machine: MachineState, callId: CallId, value: Value): void {
    const child = this.children.get(callId);
    if (child === undefined) return; // stale (already cleaned up by cancel)
    this.children.delete(callId);
    machine.threads.delete(child.id);
    if (this.status === "cancelling") {
      this.checkAllChildrenDone(machine);
      return;
    }
    this.onChildDone(machine, callId, value);
  }

  /**
   * Called by runner on `cancelAck` event whose `parent` is this thread.
   * Same bookkeeping as done; if this thread is itself cancelling we
   * progress the wait, otherwise we hand off to the variant hook (used
   * for HandleThread / ForThread targeted-cancel followups).
   */
  onChildCancelAckFromRunner(machine: MachineState, callId: CallId): void {
    const child = this.children.get(callId);
    if (child === undefined) return; // stale
    this.children.delete(callId);
    machine.threads.delete(child.id);
    if (this.status === "cancelling") {
      this.checkAllChildrenDone(machine);
      return;
    }
    this.onChildCancelAck(machine, callId);
  }

  /**
   * Called by runner on `cancel` event targeting this thread. Idempotent:
   * a second cancel while already cancelling is a no-op.
   */
  onCancelReceived(machine: MachineState): void {
    if (this.status === "cancelling") return;
    this.status = "cancelling";
    this.beginCancel(machine);
  }

  /**
   * Called by runner on `return` event targeting this thread (this thread
   * is the boundary for some `return` / `for_break` / `break`). Stores the
   * value, cancels remaining children, then `finishCancelling` once they
   * all ack.
   *
   * **Return / cancel race semantics**: queue events are dispatched in FIFO
   * order, so the resolution of a "return arrived around the same time as a
   * cancel" race is fully determined by the order in which the events were
   * pushed. Two scenarios cover the matrix:
   *
   *   1. Cancel pushed before return:
   *      `onCancelReceived` runs first → status becomes "cancelling" →
   *      `pendingReturn` is *not* set. The later return event arrives,
   *      `onReturnReceived` sees status === "cancelling" and drops the
   *      value (early return at the top of this method). When the cancel
   *      cascade finishes, `finishCancelling` emits `cancelAck` to the
   *      parent (ChildThread.finishCancelling: `pendingReturn === undefined`
   *      branch). Cancel "wins".
   *
   *   2. Return pushed before cancel:
   *      `onReturnReceived` runs first, transitions status to "cancelling",
   *      sets `pendingReturn`, and cancels remaining children. The later
   *      cancel event hits `onCancelReceived` which is idempotent on
   *      `status === "cancelling"`. When the children all ack,
   *      `finishCancelling` emits `done` (because `pendingReturn !== undefined`).
   *      Return "wins".
   *
   * Both outcomes are well-defined; the runtime is deterministic given a
   * fixed event order. Cross-applyEvent races are funneled through the
   * api-server's per-version mutex (Stage B1), so observers never see
   * interleaved partial transitions.
   */
  onReturnReceived(machine: MachineState, value: Value): void {
    if (this.status === "cancelling") return; // see scenario (1) above
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

  /**
   * Register a freshly-created child and dispatch its `onCall`. Used by
   * the runner's spawnChild path immediately after the factory.
   */
  adoptChild(machine: MachineState, callId: CallId, child: Thread): void {
    this.children.set(callId, child);
    child.onCall(machine);
  }

  // ─── Cancellation helpers ───────────────────────────────────────────────

  /**
   * Default cancel behavior: leaf threads ack their parent immediately;
   * branching threads cascade `cancel` to all live children.
   *
   * Overridden by:
   *   - ExternalThread (emits `terminate` to FFI, then waits)
   *   - APIThread (cannot be reached — `onCancelReceived` is overridden to throw)
   */
  protected beginCancel(machine: MachineState): void {
    if (this.children.size === 0) {
      this.ackCancelToParent(machine);
      return;
    }
    for (const child of this.children.values()) {
      machine.queue.push({ kind: "cancel", target: child });
    }
  }

  /**
   * Push a `cancelAck` to this thread's parent. Implemented in ChildThread.
   * APIThread overrides `onCancelReceived` so this is never reached for it.
   */
  protected ackCancelToParent(_machine: MachineState): void {
    throw new Error(
      `${this.constructor.name}: ackCancelToParent not implemented (root thread cannot ack)`,
    );
  }

  /**
   * Re-check whether cancellation can complete now that a child went away.
   * No-op if status is still "running" or children remain.
   */
  protected checkAllChildrenDone(machine: MachineState): void {
    if (this.status !== "cancelling") return;
    if (this.children.size > 0) return;
    this.finishCancelling(machine);
  }

  // ─── Abstract methods (every variant implements) ────────────────────────

  /**
   * Called once after the thread is created and registered. Variant body
   * starts here (push first child, evaluate prim, emit FFI delegate, ...).
   */
  abstract onCall(machine: MachineState): void;

  /**
   * Serialize this thread to a plain JSON object. Variants spread the
   * payload from `serializeCommon()` (or `serializeChildCommon()` for
   * non-root threads) and add their own private state. Cross-thread
   * refs are encoded as ThreadIds.
   */
  abstract serialize(): SerializedThreadAny;

  /**
   * Called when cancellation is fully complete (all children gone). Each
   * variant decides what to emit:
   *   - ChildThread: `done` (if pendingReturn) or `cancelAck` to parent
   *   - APIThread:    `terminateAck` to API, free the delegation
   */
  abstract finishCancelling(machine: MachineState): void;

  // ─── Per-variant hooks (default = throw) ────────────────────────────────

  /**
   * Variant body for "child completed normally". Default throws because
   * leaf variants (prim/ctor/external/request) cannot have children.
   */
  protected onChildDone(_machine: MachineState, _callId: CallId, _value: Value): void {
    throw new Error(
      `${this.constructor.name}: cannot receive child done (no children expected)`,
    );
  }

  /**
   * Variant body for "child cancelAck'd while parent still running". Used
   * for targeted cancellation (HandleThread / ForThread). Default throws.
   */
  protected onChildCancelAck(_machine: MachineState, _callId: CallId): void {
    throw new Error(
      `${this.constructor.name}: did not initiate a targeted cancel (onChildCancelAck)`,
    );
  }

  /**
   * Receive an `ask` event. Implemented by HandleThread.
   * Type is sufficiently broad to satisfy the runner's dispatch site, but
   * QueueEvent narrows the target to HandleThread, so this is unreachable
   * via the queue for non-handle threads.
   */
  onAsk(
    _machine: MachineState,
    _asker: Thread,
    _askId: AskId,
    _reqId: ReqId,
    _args: Record<string, Value>,
  ): void {
    throw new Error(`${this.constructor.name}: cannot receive ask`);
  }

  /**
   * Receive an `askComplete` event. Implemented by RequestThread.
   */
  onAskComplete(_machine: MachineState, _askId: AskId, _value: Value): void {
    throw new Error(`${this.constructor.name}: cannot receive askComplete`);
  }

  /**
   * Receive a `cont` event. Implemented by ForThread / HandleThread.
   */
  onCont(
    _machine: MachineState,
    _source: Thread,
    _contKind: ContKind,
    _value: Value,
    _modifiers: ReadonlyMap<VarId, Value>,
  ): void {
    throw new Error(`${this.constructor.name}: cannot receive cont`);
  }

  // ─── Snapshot — common helpers ─────────────────────────────────────────

  /**
   * Serialize the per-Thread fields common to every variant. Variant
   * `serialize()` implementations spread this object and add their own
   * fields. Object refs are stored as ids so the result is plain JSON.
   */
  protected serializeCommon(): SerializedThreadCommon {
    return {
      id: this.id,
      scopeId: this.scopeId,
      status: this.status,
      children: [...this.children.entries()].map(([callId, child]) => [
        callId,
        child.id,
      ]),
      handlers: [...this.handlers.entries()].map(([reqId, handler]) => [
        reqId,
        handler.id,
      ]),
      boundaries: serializeBoundaries(this.boundaries),
      pendingReturn: this.pendingReturn,
    };
  }

  /**
   * Apply common fields from a snapshot. Cross-thread refs are NOT linked
   * here — they are resolved in `linkCommon` after every Thread skeleton
   * has been instantiated.
   */
  protected applySnapshotCommon(serialized: SerializedThreadCommon): void {
    const writable = this as InternalMutable<Thread>;
    writable.id = serialized.id;
    writable.scopeId = serialized.scopeId;
    writable.handlers = new Map(); // filled by linkCommon
    this.children = new Map();
    this.status = serialized.status;
    // EMPTY_BOUNDARIES is frozen, so sharing the reference is safe.
    // linkCommon replaces it with the resolved Boundaries shortly after.
    this.boundaries = EMPTY_BOUNDARIES;
    this.pendingReturn = serialized.pendingReturn;
  }

  /**
   * Resolve cross-thread refs (children, handlers, boundaries) using the
   * id → Thread map built by `serializeMachine`. Called after every
   * skeleton has been registered.
   */
  protected linkCommon(
    serialized: SerializedThreadCommon,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    const writable = this as InternalMutable<Thread>;
    // Snapshot stores ThreadIds; the runtime invariant is that every entry
    // in `handlers` resolves to a HandleThread (only HandleThread inserts
    // itself into a child's handlers map). The cast reflects that — if a
    // hand-crafted snapshot violates it, downstream `onAsk` dispatch will
    // throw via the per-class hook defaults.
    writable.handlers = new Map(
      serialized.handlers.map(([reqId, threadId]) => [
        reqId,
        resolveThread(threadsById, threadId) as HandleThread,
      ]),
    );
    this.children = new Map(
      serialized.children.map(([callId, threadId]) => [
        callId,
        resolveThread(threadsById, threadId),
      ]),
    );
    this.boundaries = deserializeBoundaries(serialized.boundaries, threadsById);
  }
}

// ─── ChildThread (abstract, non-root) ───────────────────────────────────────

/**
 * Every thread except APIThread is a ChildThread. It always has a parent
 * and a parentCallId, so the cleanup machinery (`finishCancelling`,
 * `ackCancelToParent`) can address the parent directly.
 */
export abstract class ChildThread extends Thread {
  override readonly parent: Thread;
  override readonly parentCallId: CallId;

  constructor(init: ChildThreadInit) {
    super(init);
    this.parent = init.parent;
    this.parentCallId = init.parentCallId;
  }

  /**
   * Notify parent of cancellation completion. The parent's
   * `onChildDoneFromRunner` / `onChildCancelAckFromRunner` will delete
   * this thread from `machine.threads` when it processes the resulting
   * event, so this method does NOT delete itself.
   */
  override finishCancelling(machine: MachineState): void {
    if (this.pendingReturn !== undefined) {
      machine.queue.push({
        kind: "done",
        parent: this.parent,
        callId: this.parentCallId,
        value: this.pendingReturn,
      });
      return;
    }
    machine.queue.push({
      kind: "cancelAck",
      parent: this.parent,
      callId: this.parentCallId,
    });
  }

  protected override ackCancelToParent(machine: MachineState): void {
    machine.queue.push({
      kind: "cancelAck",
      parent: this.parent,
      callId: this.parentCallId,
    });
  }

  // ─── Snapshot — child-specific helpers ─────────────────────────────────

  /** Build the common-fields-plus-parent payload for variant serialize(). */
  protected serializeChildCommon(): SerializedChildThreadCommon {
    return {
      ...this.serializeCommon(),
      parent: this.parent.id,
      parentCallId: this.parentCallId,
    };
  }

  /**
   * Apply common + child-specific fields from snapshot. Parent is left
   * dangling here and resolved in `linkChildCommon` once the parent
   * skeleton is registered.
   */
  protected applySnapshotChildCommon(
    serialized: SerializedChildThreadCommon,
  ): void {
    this.applySnapshotCommon(serialized);
    const writable = this as InternalMutable<ChildThread>;
    writable.parentCallId = serialized.parentCallId;
    // `parent` is set during linkChildCommon
  }

  protected linkChildCommon(
    serialized: SerializedChildThreadCommon,
    threadsById: ReadonlyMap<ThreadId, Thread>,
  ): void {
    this.linkCommon(serialized, threadsById);
    const writable = this as InternalMutable<ChildThread>;
    writable.parent = resolveThread(threadsById, serialized.parent);
  }
}

// ─── QueueEvent ─────────────────────────────────────────────────────────────

/**
 * Events processed by the main loop (processQueue).
 *
 * Call events are split by call site so that each child thread gets a fresh
 * scope with a parent determined statically by the call kind:
 * - callBlock: top-level callable (statementCall/callTargetBlock or API entry).
 *   New scope with parent = null (isolated).
 * - callInline: inline child of a structural block (array/tuple/match/for/handle).
 *   New scope with parent = scopeId (caller's current scope).
 * - callValue: closure call (statementCall/callTargetValue).
 *   New scope with parent = capturedScopeId (closure's captured scope).
 *
 * Other events:
 * - done: child notifies parent of completion with a value.
 * - cancel: parent requests termination of a child thread (recursive).
 * - cancelAck: child notifies parent that cancellation is complete.
 * - return: child notifies parent of non-local exit (propagates to boundary).
 * - ask / askComplete / cont: target type is narrowed to the only variant
 *   that can legitimately receive each event, so the runner does not need
 *   any runtime kind discrimination.
 */
export type QueueEvent =
  | {
      kind: "callBlock";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Record<string, Value>;
    }
  | {
      kind: "callInline";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Record<string, Value>;
      scopeId: ScopeId;
      /**
       * Optional explicit handlers map for the new child. If omitted, the
       * runner copies `parent.handlers` by value. HandleThread uses this
       * to spawn its main target with augmented handlers (parent + this
       * handle's own overrides) while still spawning handler-body /
       * thenClause without those overrides.
       */
      handlersOverride?: ReadonlyMap<ReqId, HandleThread>;
    }
  | {
      kind: "callValue";
      parent: Thread;
      callId: CallId;
      blockId: BlockId;
      args: Record<string, Value>;
      capturedScopeId: ScopeId;
    }
  | {
      kind: "done";
      parent: Thread;
      callId: CallId;
      value: Value;
    }
  | {
      kind: "cancel";
      target: Thread;
    }
  | {
      kind: "cancelAck";
      parent: Thread;
      callId: CallId;
    }
  | {
      /**
       * Global exit (return / for_break / break) delivered directly to
       * its boundary thread.
       */
      kind: "return";
      target: Thread;
      value: Value;
      exitKind: ExitKind;
    }
  | {
      /**
       * `request foo(args)` from a RequestThread, delivered to the
       * handler-owning HandleThread registered in the asker's `handlers`.
       */
      kind: "ask";
      target: HandleThread;
      asker: Thread;
      askId: AskId;
      reqId: ReqId;
      args: Record<string, Value>;
    }
  | {
      /**
       * Reply to a previously-issued `ask`. Sent by HandleThread back to
       * the asker (RequestThread) after a handler resumed via `next`.
       */
      kind: "askComplete";
      target: RequestThread;
      askId: AskId;
      value: Value;
    }
  | {
      /**
       * `next` / `for_next` (statementCont) delivered directly to its
       * boundary thread. Modifiers are pre-evaluated by the source.
       */
      kind: "cont";
      target: HandleThread | ForThread;
      source: Thread;
      contKind: ContKind;
      value: Value;
      modifiers: ReadonlyMap<VarId, Value>;
    };
