import type { ExitKind, ContKind, ExternalName, IRModule, ReqId, VarId } from "../ir/types.js";
import type { DelegationId, ThreadId } from "./id.js";
import type { Value } from "./value.js";

// ─── Inbound (外部 → machine) ───────────────────────────────────────────────

export type InboundEvent =
  | {
      kind: "invoke";
      qualifiedName: string;
      args: Map<string, Value>;
      delegationId: DelegationId;
    }
  | {
      kind: "invokeAck";
      delegationId: DelegationId;
      value: Value;
    }
  | {
      kind: "cancel";
      delegationId: DelegationId;
    }
  | {
      kind: "load";
      irModule: IRModule;
    };

// ─── Outbound (machine → 外部) ──────────────────────────────────────────────

export type OutboundEvent =
  | {
      kind: "callExternal";
      externalName: ExternalName;
      args: Map<string, Value>;
      delegationId: DelegationId;
    }
  | {
      kind: "cancelExternal";
      delegationId: DelegationId;
    }
  | {
      kind: "invokeDone";
      delegationId: DelegationId;
      value: Value;
    }
  | {
      kind: "invokeCancelled";
      delegationId: DelegationId;
    };

// ─── Internal (machine 内部 event queue) ────────────────────────────────────

export type InternalEvent =
  | {
      kind: "evalThread";
      threadId: ThreadId;
    }
  | {
      kind: "threadDone";
      threadId: ThreadId;
      value: Value;
    }
  | {
      kind: "threadExited";
      threadId: ThreadId;
      exitKind: ExitKind;
      value: Value;
    }
  | {
      kind: "threadCont";
      threadId: ThreadId;
      contKind: ContKind;
      value: Value | null;
      modifiers: [VarId, Value][];
    }
  | {
      kind: "threadRequest";
      threadId: ThreadId;
      reqId: ReqId;
      args: Map<string, Value>;
      outputVarId: VarId;
    }
  | {
      kind: "threadCancelled";
      threadId: ThreadId;
    };
