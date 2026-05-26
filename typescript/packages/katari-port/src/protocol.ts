// Wire-level IPC protocol. 11 message variants, all `ipc`-prefixed.
//
// Parent → Child (5):
//   - ipcDelegate           : fresh invocation
//   - ipcDelegateRestarted  : re-issued after a parent restart
//   - ipcTerminate          : cancel an in-flight delegation
//   - ipcChildDelegateAck   : result of a child agent started via
//                             katari.delegate
//   - ipcChildTerminateAck  : cancel completion for a child agent
//
// Child → Parent (6):
//   - ipcReady              : bundle finished evaluating, ready to dispatch
//   - ipcDelegateAck        : ext handler completed
//   - ipcDelegateError      : ext handler threw (or no handler registered)
//   - ipcTerminateAck       : ext handler observed the terminate
//   - ipcChildDelegate      : ext wants to start a CORE-side child agent
//   - ipcChildTerminate     : ext wants to cancel a child agent
//
// Escalation (= ext → core req cap) is **not** on the wire — child
// agents emit req asks from inside CORE; the FfiModule relays the
// resulting escalate event on the bus to the parent agent's handle
// scope without involving the sidecar at all.
//
// The wire is still pre-publish, so there's no protocolVersion field.
// Readers fail-fast on unknown `type` values.

import type { RawValue } from "@katari-lang/types";

export type ParentToChild =
  | {
      type: "ipcDelegate";
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcDelegateRestarted";
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcTerminate";
      delegationId: string;
    }
  | {
      type: "ipcChildDelegateAck";
      delegationId: string;
      value: RawValue;
    }
  | {
      type: "ipcChildTerminateAck";
      delegationId: string;
    };

export type ChildToParent =
  | { type: "ipcReady" }
  | {
      type: "ipcDelegateAck";
      delegationId: string;
      value: RawValue;
    }
  | {
      type: "ipcDelegateError";
      delegationId: string;
      message: string;
    }
  | {
      type: "ipcTerminateAck";
      delegationId: string;
    }
  | {
      type: "ipcChildDelegate";
      parentDelegationId: string;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcChildTerminate";
      delegationId: string;
    };
