// Event: the unit of communication between endpoints (= modules).
//
// Every event carries `from` / `to` Endpoints and a kind-tagged payload.
// Core of the 3-module + 6-event symmetric design:
//
//   - 6 cross-module events: delegate, delegateAck, terminate, terminateAck,
//     escalate, escalateAck. Valid for any (from, to) pair.
//   - delegate / escalate identify the target via `agentDefId` (= a
//     module-local opaque identifier. Only the receiving module decodes it).
//   - `from` / `to` are Endpoint strings; the bus layer resolves the
//     identifying module (the engine itself has no "CORE" | "API" | "FFI"
//     enum).
//
// **Engine-internal events** (`from === self && to === self`) are control
// signals of the thread tree: create / done / cancel / cancelAck / ask /
// askAck. These stay within the engine's internal queue and do not flow
// onto the cross-module bus.

import type { AgentDefId } from "../agent-def-id.js";
import type { Json } from "../json.js";
import type { Endpoint } from "./endpoint.js";
import type { AskId, CallId, DelegationId, EscalationId, ThreadId } from "./id.js";
import type { Value } from "./value.js";

// ─── External payloads (3 module + 6 event protocol) ───────────────────────

export type ExternalEventPayload =
  | {
      /** Start a new agent on the receiver. */
      kind: "delegate";
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      argument: Value | undefined;
      /**
       * The callee value's resolved generic substitution (from a `foo[args]`
       * instantiation), recorded by the receiver as the new agent activation's
       * ambient substitution — used to fill the `$generic` placeholders a
       * `foo[T]` inside the body leaves behind. Absent for a non-generic call.
       */
      generics?: Record<string, Json>;
    }
  | {
      /** Successful completion of a `delegate`. */
      kind: "delegateAck";
      delegationId: DelegationId;
      value: Value;
    }
  | {
      /** Cancel an in-flight delegate. */
      kind: "terminate";
      delegationId: DelegationId;
    }
  | {
      /** Acknowledge a `terminate`. */
      kind: "terminateAck";
      delegationId: DelegationId;
    }
  | {
      /**
       * Mid-flight, the receiver of a delegation needs a capability —
       * it asks the sender to perform an agent on its behalf.
       *
       *   - `delegationId` identifies the parent delegation context.
       *   - `escalationId` is the sender's local id for the matching ack
       *     (allocated by whoever emits this escalate).
       *   - `agentDefId` is the requested capability, decoded by the
       *     receiver of THIS escalate event.
       */
      kind: "escalate";
      delegationId: DelegationId;
      escalationId: EscalationId;
      agentDefId: AgentDefId;
      argument: Value | undefined;
      /**
       * Present when this escalate is a CONTROL-flow unwind (return / break /
       * next / break-for / next-for) crossing the delegation boundary toward a
       * lexical ancestor, rather than a capability request. The receiver
       * reconstructs the upward `ask` directly from this (it IS the
       * `ControlAskKind`, value + target + mods inline) and does NOT set up an
       * escalateAck round-trip: a control unwind never resumes the asker — the
       * ancestor's catch fires a cancel cascade that flows a `terminate` back
       * down and tears the escalating delegation (in "stop phase") down.
       *
       * When `control` is set, `agentDefId` is an ignored sentinel and
       * `argument` is undefined (the value rides inside `control`).
       */
      control?: ControlAskKind;
    }
  | {
      /** Reply to an `escalate`. Matched via `escalationId`. */
      kind: "escalateAck";
      escalationId: EscalationId;
      value: Value;
    };

// ─── Internal payloads (engine-private; from === to === selfEndpoint) ──────
//
// `AskKind` enumerates the special asks that propagate via bubbling. New
// kinds (e.g. future tracing taps) can be added without touching engine
// dispatch — only the variant that catches them needs to know.

import type { BlockId, QualifiedName } from "../ir/types.js";

/**
 * Pre-evaluated state-var modifiers attached to `next` / `next-for` asks.
 * Keyed by the target VarId, valued by the new Value to write into scope.
 */
export type ModMap = Record<number, Value>;

/**
 * AskKind: every kind of "ask the parent for something" the engine
 * supports, with the data each kind needs carried inline.
 *
 * - `request`  caught by the HandleThread that owns the reqId; askAck-terminating.
 * - `next`     caught by the same HandleThread; askAck-terminating
 *              (with state-var modifiers applied to the handle's scope).
 * - `next-for` caught by the surrounding ForThread; askAck-terminating
 *              (advances the iteration with state-var mods applied).
 * - `return`   caught by the agent UserThread; done-terminating.
 * - `break`    caught by the surrounding HandleThread; done-terminating.
 * - `break-for` caught by the surrounding ForThread; done-terminating.
 *
 * "askAck-terminating" means the boundary replies via `askAck` and the
 * asker resumes; "done-terminating" means the boundary cancels its
 * children and emits `done` upward (no askAck travels back).
 */
export type AskKind =
  | { kind: "request"; reqId: QualifiedName; argument: Value | undefined }
  | { kind: "next"; value: Value; mods: ModMap; target: BlockId }
  | { kind: "next-for"; value: Value; mods: ModMap; target: BlockId }
  | { kind: "return"; value: Value; target: BlockId }
  | { kind: "break"; value: Value; target: BlockId }
  | { kind: "break-for"; value: Value; target: BlockId };

/**
 * The control-flow asks (everything except `request`). These carry a lexical
 * `target` BlockId and are routed to the thread whose `blockId` matches it —
 * escalating across delegation boundaries when the target lives in a lexical
 * ancestor (see `ExitData.target`). A `request` is NOT control flow: it is
 * dynamically routed to the nearest handle owning its reqId, so it has no
 * `target`.
 */
export type ControlAskKind = Exclude<AskKind, { kind: "request" }>;

export type InternalEventPayload =
  | {
      /**
       * Run the variant's create op. The thread record itself must already
       * be in `state.threads[threadId]` when this event is enqueued —
       * the spawning code is responsible for allocating the record (with
       * its parent / parentCallId / scopeId / variant-specific fields)
       * and registering it before queueing this event.
       */
      kind: "create";
      threadId: ThreadId;
    }
  | {
      kind: "done";
      target: ThreadId;
      callId: CallId;
      value: Value;
    }
  | {
      kind: "cancel";
      target: ThreadId;
    }
  | {
      kind: "cancelAck";
      target: ThreadId;
      callId: CallId;
    }
  | {
      /**
       * An `ask` bubbling up the thread tree. The target is the immediate
       * parent of the asker (or proxy thread). The kind-specific data
       * (value, args, mods, reqId) lives on `askKind`. `childCallId`
       * tells the receiver which of its children sent this — used by
       * boundary catches that need to identify the originating subtree
       * (e.g. HandleThread routing askAck back through the right child).
       */
      kind: "ask";
      target: ThreadId;
      askId: AskId;
      askKind: AskKind;
      childCallId: CallId;
    }
  | {
      kind: "askAck";
      target: ThreadId;
      askId: AskId;
      value: Value;
    };

// ─── Event ─────────────────────────────────────────────────────────────────

export type EventPayload = ExternalEventPayload | InternalEventPayload;

export type Event = {
  from: Endpoint;
  to: Endpoint;
  payload: EventPayload;
};

/**
 * Cross-module event over the bus. `payload` is restricted to one of the
 * 6 external event kinds (delegate / delegateAck / terminate / terminateAck
 * / escalate / escalateAck). Internal events never cross module boundary.
 */
export type ExternalEvent = {
  from: Endpoint;
  to: Endpoint;
  payload: ExternalEventPayload;
};

/** Type guard: is this event one the engine can dispatch internally? */
export function isInternal(payload: EventPayload): payload is InternalEventPayload {
  switch (payload.kind) {
    case "create":
    case "done":
    case "cancel":
    case "cancelAck":
    case "ask":
    case "askAck":
      return true;
    default:
      return false;
  }
}
