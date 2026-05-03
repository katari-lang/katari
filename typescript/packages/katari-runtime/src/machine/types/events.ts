import type { IRModule } from "../../ir/types.js";
import { DelegationId, EscalationId, SnapshotId } from "./id.js";
import type { Value } from "./value.js";

export type ManagementEvent = {
  kind: "load";
  irModuleId: SnapshotId;
  irModule: IRModule;
};

export type Endpoint = "API" | "FFI" | "CORE";

/**
 *  FFI <-> CORE
 *  API <-> CORE
 *
 * FFI: External function (bundled JS)
 * API: User interaction via API
 * CORE: Core runtime, state mahcine
 */
export type MachineEventBase =
  | {
      kind: "invoke";
      qualifiedName: string;
      input: Value;
      delegationId: DelegationId;
    }
  | {
      kind: "invoke-ack";
      delegationId: DelegationId;
      output: Value;
    }
  | {
      kind: "cancel";
      delegationId: DelegationId;
    }
  | {
      kind: "cancel-ack";
      delegationId: DelegationId;
    }
  | {
      kind: "escalate";
      qualifiedName: string;
      input: Value;
      escalationId: EscalationId;
    }
  | {
      kind: "escalate-ack";
      escalationId: EscalationId;
      output: Value;
    };

// escalation のキャンセルはできない？ → 要検討

export type MachineEvent = MachineEventBase & {
  from: Endpoint;
  to: Endpoint;
};
