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
      kind: "escalate";
      target: QualifiedName;
      args: Record<string, Value>;
      escalationId: EscalationId;
    }
  | {
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

export type AskKind =
  /** algebraic-effect request; caught by the relevant HandleThread */
  | { kind: "request"; reqId: ReqId }
  /** handler resume; caught by the same HandleThread that holds the req */
  | { kind: "next"; reqId: ReqId }
  /** for-loop continue; caught by the surrounding ForThread */
  | { kind: "next-for" }
  /** agent return; caught by the surrounding agent UserThread (done-terminating) */
  | { kind: "return" }
  /** handle break; caught by the surrounding HandleThread (done-terminating) */
  | { kind: "break" }
  /** for break; caught by the surrounding ForThread (done-terminating) */
  | { kind: "break-for" };

/** Pre-evaluated state-var modifiers attached to `next` / `next-for` asks. */
export type ModMap = Record<number, Value>;

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
      kind: "ask";
      target: ThreadId;
      askId: AskId;
      askKind: AskKind;
      payload: Value;
      mods?: ModMap;
      /** Identifies which child of the target this ask came from. */
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
