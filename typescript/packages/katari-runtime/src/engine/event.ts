// Event: the unit of communication between endpoints.
//
// Every event carries `from` / `to` Endpoints and a kind-tagged payload.
// The engine inspects `event.to` to decide whether to consume the event
// (when `to === selfEndpoint`) or treat it as outbound. There is no
// hard-coded `"CORE" | "API" | "FFI"` enum — endpoints are opaque strings.
//
// **Engine-internal events** (`from === self && to === self`) drive the
// thread tree. They include `create` / `done` / `cancel` / `cancelAck` /
// `ask` / `askAck`.
//
// **External events** (one of `from` / `to` is *not* the engine) are
// translated by the host layer (DelegationRouter) into engine-internal
// `create` events and outbound delegateAck/terminateAck events. The engine
// itself never special-cases delegation ids.

import type { QualifiedName } from "../ir/types.js";
import type { Endpoint } from "./endpoint.js";
import type {
  AskId,
  CallId,
  DelegationId,
  EscalationId,
  ThreadId,
} from "./id.js";
import type { Value } from "./value.js";

// ─── External payloads (over the public protocol) ──────────────────────────

export type ExternalEventPayload =
  | {
      kind: "delegate";
      targetBlock: QualifiedName;
      args: Record<string, Value>;
      delegationId: DelegationId;
    }
  | {
      kind: "delegateAck";
      delegationId: DelegationId;
      value: Value;
    }
  | {
      kind: "terminate";
      delegationId: DelegationId;
    }
  | {
      kind: "terminateAck";
      delegationId: DelegationId;
    }
  | {
      /**
       * External party requests a capability (request) from inside an
       * agent we are running. `delegationId` identifies which inbound
       * delegation the escalation belongs to (i.e. which AgentThread
       * should receive the proxied ask). `request` is the qualified name
       * of the request being asked.
       */
      kind: "escalate";
      delegationId: DelegationId;
      escalationId: EscalationId;
      request: QualifiedName;
      args: Record<string, Value>;
    }
  | {
      /**
       * Reply to an outbound escalate. `escalationId` matches the id
       * recorded on the corresponding ExternalThread.pendingEscalations.
       */
      kind: "escalateAck";
      escalationId: EscalationId;
      value: Value;
    };

// ─── Internal payloads (engine-private; from === to === selfEndpoint) ──────
//
// `AskKind` enumerates the special asks that propagate via bubbling. New
// kinds (e.g. future tracing taps) can be added without touching engine
// dispatch — only the variant that catches them needs to know.

import type { ReqId } from "../ir/types.js";

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
  | { kind: "request"; reqId: ReqId; args: Record<string, Value> }
  | { kind: "next"; value: Value; mods: ModMap }
  | { kind: "next-for"; value: Value; mods: ModMap }
  | { kind: "return"; value: Value }
  | { kind: "break"; value: Value }
  | { kind: "break-for"; value: Value };

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

/** Type guard: is this event one the engine can dispatch internally? */
export function isInternal(
  payload: EventPayload,
): payload is InternalEventPayload {
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
