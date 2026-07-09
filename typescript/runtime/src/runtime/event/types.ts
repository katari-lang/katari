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

/** What a `delegate` summons: a top-level named agent, a closure (block + captured scope), or an `external`
 *  (FFI / http) handler. The target says *what* the callee runs, not *where* — which call reactor handles an
 *  external delegate (`ffi` or `http`) is the event's `to`, stamped from the block's `reactor` marker at the
 *  emit site (see `createExternal`), so the target does not repeat it. The external handler runs against its
 *  `key` (a sidecar-registry name, not the IR); its `snapshot` still matters — the handler lives in that
 *  snapshot's compiled sidecar bundle, so the ffi transport spawns the right one. It is the calling agent's
 *  snapshot (an agent and its FFI handler deploy together; http ignores it). An external delegate behaves
 *  like any sub-call; only its `to` differs. */
export type DelegateTarget =
  | { kind: "named"; name: QualifiedName; snapshot: SnapshotId }
  | { kind: "closure"; blockId: BlockId; scopeId: ScopeId; snapshot: SnapshotId; module: string }
  | {
      kind: "external";
      key: string;
      snapshot: SnapshotId;
      /** A reactor-backed `tool` value's execution context, riding the target out-of-band (the value
       *  analog of a closure's `scopeId`). Absent for a compiled `external agent` call. */
      context?: Value;
    };

/** Which reactor an external event originates from / is destined for. An event is self-routing: the
 *  substrate dispatches purely by `to` (`registry[to]`), and a reply inverts from/to. The engine emits
 *  routing-less `ExternalEventBody`s; the CORE reactor stamps from/to when they leave it. `ffi` runs FFI
 *  (sidecar) handlers, `http` the built-in http client — an external call is a `delegate` to one of them,
 *  exactly like a core sub-call, `webhook` the dynamically generated inbound endpoints
 *  (`webhook.inbound` — the outside world calling the program), and `mcp` the built-in MCP client
 *  (`prelude.mcp.*` — connect / list / call against an MCP server). */
export type ReactorName = "core" | "api" | "ffi" | "http" | "webhook" | "mcp";

/** An external event's payload — what the engine emits, before routing is stamped on it. */
export type ExternalEventBody =
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
      /** The escalating child's delegation. It routes both legs by external vocabulary alone: the parent
       *  finds the proxy via it (`delegationCaller` → the caller, then its `DelegateThread` by id), and
       *  the `escalateAck` finds the raiser back through it (`delegationChild` → this child). */
      delegation: DelegationId;
      /** This escalation's id — the per-escape correlation the `escalateAck` echoes (one delegation can
       *  have several escapes in flight). Opaque to the actor; the raiser's *Agent thread* maps it back to
       *  the internal `askId` it escaped under (its `escalations` bridge). */
      escalation: EscalationId;
      /** The ask that escaped the child instance: a `request` (capability), or a control-flow unwind
       *  (`break` / `next` / `return`) crossing the boundary toward a lexical ancestor (via a closure). */
      ask: AskKind;
    }
  | { kind: "escalateAck"; delegation: DelegationId; escalation: EscalationId; value: Value };

/** A routed external event: a payload plus its `from` (issuing reactor) and `to` (destination reactor). The
 *  substrate routes by `to`; a reply inverts from/to. This is the wire form an actor sends / receives.
 *
 *  `run` is the event's trace context — the id of the run's permanent api-side *run instance* (see the
 *  ApiReactor: a run IS that instance, and `runs.id` is its id), whose causal tree the event belongs to.
 *  It rides the envelope exactly like routing: an instance-originated event carries its instance's ambient
 *  run (recorded at delegate-accept from the summoning event's `run`, the same way `callerReactor` is
 *  recorded from its `from`), and a reply that has no instance derives it from the inbound event it
 *  answers. The run instance seeds it — a run's launching `delegate` carries `run = that instance's id`.
 *  It exists so every event can be attributed to its run at the commit boundary (the `run_events` journal)
 *  without any tree walk. */
export type ExternalEvent = ExternalEventBody & {
  from: ReactorName;
  to: ReactorName;
  run: InstanceId;
};

/** The snapshot a delegate target is pinned to: the version whose IR a `named` / `closure` runs, or whose
 *  compiled sidecar bundle hosts an `external` handler. Every target carries one. */
export function agentSnapshot(target: DelegateTarget): SnapshotId {
  return target.snapshot;
}

/** The value an `escalate` carries up across the instance boundary: a `request`'s argument, or a control
 *  escape's (`next` / `break` / `return`) carried value. The two-step reown uses it — the raiser releases
 *  the resources this value captures on send, the receiver reowns them on receipt. */
export function escalateValue(ask: AskKind): Value | null {
  return ask.kind === "request" ? ask.argument : ask.value;
}

// FFI is no longer a private side channel on the external thread: an external call is a `delegate` to the
// `ffi` reactor (above), and its completion comes back as a `delegateAck` / `escalate` / `terminateAck` like
// any sub-call. The transport's own completion shape (ffi reactor ↔ sidecar) lives with the transport, in
// `external/`.
