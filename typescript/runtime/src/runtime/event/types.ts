// Events: the runtime's two-layer communication model (see docs/2026-06-15-runtime-domain-model.md).
//
//   - Internal events stay within one instance's thread tree (thread ↔ thread):
//       call / callAck, ask / askAck, cancel / cancelAck.
//   - External events cross instance boundaries (instance ↔ instance), handled by the same single
//     CORE engine (no module bus in v0.1.0):
//       delegate / delegateAck, escalate / escalateAck, terminate / terminateAck.
//
// The two layers are isomorphic request/reply pairs: call⟷delegate, ask⟷escalate, cancel⟷terminate.
// Internal events route by `ThreadId`; external events route by `DelegationId` / `EscalationId`.

import type { BlockId, QualifiedName } from "@katari-lang/types";
import type {
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  InstanceId,
  ScopeId,
  SnapshotId,
  ThreadId,
} from "../ids.js";
import type { GenericSubstitution, Value } from "../value/types.js";

// ─── Internal (intra-instance, thread ↔ thread) ────────────────────────────────────────────────

/** Pre-evaluated state-var modifiers on `next` / `next-for` asks: VariableId -> new Value. (Mirrors
 *  the IR's `with (name = e, ...)` `modifiers`.) */
export type ModifierMap = Record<number, Value>;

/**
 * Every kind of "ask the parent for something", with the data each carries inline. `request` is
 * dynamically routed to the nearest handle owning the request; the rest carry a lexical `target`
 * block and route to the thread whose block matches it (escalating across instances when the target
 * is a lexical ancestor). "askAck-terminating" asks resume the asker; the others unwind (no askAck).
 */
export type AskKind =
  | { kind: "request"; request: QualifiedName; argument: Value | null }
  | { kind: "next"; value: Value; modifiers: ModifierMap; target: BlockId }
  | { kind: "next-for"; value: Value; modifiers: ModifierMap; target: BlockId }
  | { kind: "return"; value: Value; target: BlockId }
  | { kind: "break"; value: Value; target: BlockId }
  | { kind: "break-for"; value: Value; target: BlockId };

export type InternalEvent =
  // Run a freshly-spawned thread's `create` step. The parent already built the thread object and seeded
  // its scope; this just schedules the first step (kept an event so the queue, not the stack, drives it).
  | { kind: "create"; thread: ThreadId }
  // A child finished; deliver its value to the parent's `callId` slot.
  | { kind: "callAck"; target: ThreadId; callId: CallId; value: Value }
  | { kind: "cancel"; target: ThreadId }
  | { kind: "cancelAck"; target: ThreadId; callId: CallId }
  // An ask bubbling up to its parent. `from` is the immediate sender (the asker, or a proxy re-raising
  // a child's ask): it routes the eventual `askAck` back down, and names the child a handle/for unwinds.
  | { kind: "ask"; target: ThreadId; from: ThreadId; askId: AskId; ask: AskKind }
  | { kind: "askAck"; target: ThreadId; askId: AskId; value: Value };

// ─── External (inter-instance) ──────────────────────────────────────────────────────────────────

/** What a `delegate` summons: a top-level named agent, or a closure (block + captured scope). */
export type DelegateTarget =
  | { kind: "named"; name: QualifiedName; snapshot: SnapshotId }
  | { kind: "closure"; blockId: BlockId; scopeId: ScopeId; snapshot: SnapshotId };

export type ExternalEvent =
  | {
      kind: "delegate";
      delegation: DelegationId;
      target: DelegateTarget;
      argument: Value | null;
      /** The callee value's resolved generic substitution (`foo[args]`), recorded as the new
       *  instance's ambient substitution. Absent for a non-generic call. */
      generics?: GenericSubstitution;
    }
  | { kind: "delegateAck"; delegation: DelegationId; value: Value }
  | { kind: "terminate"; delegation: DelegationId }
  | { kind: "terminateAck"; delegation: DelegationId }
  | {
      kind: "escalate";
      /** The escalating child's delegation (so the parent finds the DelegateThread proxying it). */
      delegation: DelegationId;
      /** This escalation's id, correlating the `escalateAck` (only a `request` ask is answered). */
      escalation: EscalationId;
      /** The ask that escaped the child instance: a `request` (capability), or a control-flow unwind
       *  (`break` / `next` / `return`) crossing the boundary toward a lexical ancestor (via a closure). */
      ask: AskKind;
    }
  | { kind: "escalateAck"; escalation: EscalationId; value: Value };

export type EngineEvent = InternalEvent | ExternalEvent;

// ─── FFI completion + actor mailbox (the "external consumer" input) ───────────────────────────────

/**
 * An external (FFI) process result fed back to resume the suspended `ExternalThread` that dispatched
 * it. FFI is deliberately NOT an inter-instance event (domain-model R3: an external call is an external
 * *thread* suspend/resume, not an instance) — its dispatch and completion are a private side channel
 * between the external thread and the single FFI abstraction (`ExternalRunner`). It still re-enters
 * through the actor's serial mailbox, so a completion can never race a turn already in flight.
 */
export type FfiResult =
  | { kind: "ffiResult"; instance: InstanceId; thread: ThreadId; value: Value }
  | { kind: "ffiError"; instance: InstanceId; thread: ThreadId; message: string };

/**
 * The project actor's serial mailbox input (the "external consumer"): inter-instance external events
 * plus FFI completions. The actor pulls one at a time, routes it to the owning instance, drives that
 * instance's internal turn to quiescence, persists, then flushes any newly produced external events
 * back here. API commands (startRun / cancel / answerEscalation) are translated by the façade into the
 * external events above, so they need no separate mailbox variant.
 */
export type ActorMessage = ExternalEvent | FfiResult;

/** Type guard: is this mailbox message an FFI completion (vs an inter-instance external event)? */
export function isFfiResult(message: ActorMessage): message is FfiResult {
  return message.kind === "ffiResult" || message.kind === "ffiError";
}

/** Type guard: is this an engine-internal event (vs an inter-instance one)? */
export function isInternalEvent(event: EngineEvent): event is InternalEvent {
  switch (event.kind) {
    case "create":
    case "callAck":
    case "cancel":
    case "cancelAck":
    case "ask":
    case "askAck":
      return true;
    default:
      return false;
  }
}
