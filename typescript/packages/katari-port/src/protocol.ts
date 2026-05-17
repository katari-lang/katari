// Wire-level IPC protocol — v2. 11 message variants, all `ipc`-prefixed,
// every payload tagged with `protocolVersion` so receivers fail-fast on
// a mismatch.
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

import type { RawValue } from "katari-runtime";

export const PROTOCOL_VERSION = 2;

export type ParentToChild =
  | {
      type: "ipcDelegate";
      protocolVersion: number;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcDelegateRestarted";
      protocolVersion: number;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcTerminate";
      protocolVersion: number;
      delegationId: string;
    }
  | {
      type: "ipcChildDelegateAck";
      protocolVersion: number;
      delegationId: string;
      value: RawValue;
    }
  | {
      type: "ipcChildTerminateAck";
      protocolVersion: number;
      delegationId: string;
    };

export type ChildToParent =
  | { type: "ipcReady"; protocolVersion: number }
  | {
      type: "ipcDelegateAck";
      protocolVersion: number;
      delegationId: string;
      value: RawValue;
    }
  | {
      type: "ipcDelegateError";
      protocolVersion: number;
      delegationId: string;
      message: string;
    }
  | {
      type: "ipcTerminateAck";
      protocolVersion: number;
      delegationId: string;
    }
  | {
      type: "ipcChildDelegate";
      protocolVersion: number;
      parentDelegationId: string;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcChildTerminate";
      protocolVersion: number;
      delegationId: string;
    };
