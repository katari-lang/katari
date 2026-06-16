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

/** The control-flow asks (everything except `request`), routed by lexical `target` block. */
export type ControlAskKind = Exclude<AskKind, { kind: "request" }>;

export type InternalEvent =
  // Start a child thread already registered in the instance's thread map (was `create`).
  | { kind: "call"; thread: ThreadId }
  // A child finished; deliver its value to the parent's `callId` slot (was `done`).
  | { kind: "callAck"; target: ThreadId; callId: CallId; value: Value }
  | { kind: "cancel"; target: ThreadId }
  | { kind: "cancelAck"; target: ThreadId; callId: CallId }
  // An ask bubbling up to the asker's immediate parent. `childCallId` identifies the originating child.
  | { kind: "ask"; target: ThreadId; askId: AskId; ask: AskKind; childCallId: CallId }
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
      delegation: DelegationId;
      escalation: EscalationId;
      request: QualifiedName;
      argument: Value | null;
      /** Present when this escalate is a control-flow unwind crossing the instance boundary toward a
       *  lexical ancestor, rather than a capability request (no escalateAck round-trip then). */
      control?: ControlAskKind;
    }
  | { kind: "escalateAck"; escalation: EscalationId; value: Value };

export type EngineEvent = InternalEvent | ExternalEvent;

/** Type guard: is this an engine-internal event (vs an inter-instance one)? */
export function isInternalEvent(event: EngineEvent): event is InternalEvent {
  switch (event.kind) {
    case "call":
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
