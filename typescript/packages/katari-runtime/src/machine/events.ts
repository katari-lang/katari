import type { ContKind, ExitKind, ReqId, VarId } from "../ir/types.js";
import type { DelegationId, EscalationId, ThreadId } from "./id.js";
import type { Value } from "./value.js";

// ─── Endpoint ───────────────────────────────────────────────────────────────

/** One of the three communication endpoints. One side is always CORE. */
export type Endpoint = "API" | "CORE" | "FFI";

// ─── MachineEvent (unified, directional) ────────────────────────────────────

/**
 * Payload variants for machine events.
 *
 * Current:
 *   delegate       API→CORE  (user starts agent)
 *   delegateAck    CORE→API  (core returns result)
 *   terminate       API→CORE  (user terminates agent)
 *   terminateAck    CORE→API  (core acknowledges terminate)
 *   delegate       CORE→FFI  (external function call)
 *   delegateAck    FFI→CORE  (external function result)
 *   terminate       CORE→FFI  (terminate external call)
 *   terminateAck    FFI→CORE  (external terminate acknowledged)
 *
 * Future:
 *   escalate     FFI→CORE  (FFI sends request to core)
 *   escalateAck  CORE→FFI  (core responds to FFI request)
 *   delegate       FFI→CORE  (FFI calls core function)
 *   delegateAck    CORE→FFI  (core returns to FFI)
 *   escalate     CORE→API  (core sends request to user)
 *   escalateAck  API→CORE  (user responds to request)
 */
export type MachineEventPayload =
  | {
      kind: "delegate";
      qualifiedName: string;
      args: Map<string, Value>;
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
      qualifiedName: string;
      args: Map<string, Value>;
      escalationId: EscalationId;
    }
  | {
      kind: "escalateAck";
      escalationId: EscalationId;
      value: Value;
    };

/** A machine event with direction (from → to). One side is always CORE. */
export type MachineEvent = MachineEventPayload & {
  from: Endpoint;
  to: Endpoint;
};
