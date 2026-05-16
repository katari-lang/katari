// Wire-level IPC protocol between the Katari runtime (parent) and the
// katari-port subprocess (child). 7 message variants, all tagged with
// `protocolVersion` so receivers can fail-fast on a mismatch.
//
// Parent → Child (3 variants):
//   - delegate          : fresh invocation
//   - delegateRestored  : same payload as delegate but re-issued after a
//                         parent restart; handler should treat as
//                         at-least-once delivery
//   - terminate         : cancel an in-flight delegation
//
// Child → Parent (4 variants):
//   - ready             : sent once after the subprocess finishes loading
//                         the user bundle (= all `katari.agent(...)`
//                         registrations have run)
//   - delegateAck       : delegation completed successfully
//   - delegateError     : delegation failed (handler threw or unknown
//                         agentDefId)
//   - terminateAck      : terminate is observed (either cancelled
//                         in-flight, completed before the terminate
//                         arrived, or unknown delegation id — all three
//                         produce the same ack so the parent's
//                         send/recv stays a direct 1:1 pair)

import type { RawValue } from "katari-runtime";

export const PROTOCOL_VERSION = 1;

export type ParentToChild =
  | {
      type: "delegate";
      protocolVersion: number;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "delegateRestored";
      protocolVersion: number;
      delegationId: string;
      agentDefId: string;
      args: Record<string, RawValue>;
    }
  | {
      type: "terminate";
      protocolVersion: number;
      delegationId: string;
    };

export type ChildToParent =
  | { type: "ready"; protocolVersion: number }
  | {
      type: "delegateAck";
      protocolVersion: number;
      delegationId: string;
      value: RawValue;
    }
  | {
      type: "delegateError";
      protocolVersion: number;
      delegationId: string;
      message: string;
    }
  | {
      type: "terminateAck";
      protocolVersion: number;
      delegationId: string;
    };
