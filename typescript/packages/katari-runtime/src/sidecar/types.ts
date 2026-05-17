// Sidecar bundle + IPC protocol types — protocol v2.
//
// **Sidecar**: subprocess that the FFI Runner spawns per snapshot. The
// user's bundled JS (built with the Katari CLI + `katari-port`) runs
// inside, receives `ParentToChild` over stdin, and responds with
// `ChildToParent` over stdout (one JSON object per line). stderr is
// passed through to the parent for log output.
//
// **Protocol versioning**: every message carries `protocolVersion`.
// Receivers fail-fast on mismatch so a new parent talking to an old
// child (or vice-versa) is detected before any state diverges.
//
// **v1 → v2 delta**: v2 adds the "ext spawns a CORE-side child agent"
// path (`ipcChildDelegate` / `ipcChildTerminate` from C→P,
// `ipcChildDelegateAck` / `ipcChildTerminateAck` from P→C) plus an
// `ipc` prefix on every variant to disambiguate from bus event kinds.
// Escalate / log / shutdown are still not on the wire — FfiModule
// relays escalate on the bus, console.* is redirected to stderr, and
// graceful shutdown uses SIGTERM → SIGKILL.

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId } from "../engine/id.js";
import type { QualifiedName } from "../ir/types.js";
import type { RawValue } from "../value-codec.js";

void (null as unknown as QualifiedName); // referenced via AgentDefId encoding

/** Current wire protocol version. Bump when adding/changing a message. */
export const PROTOCOL_VERSION = 2;

/**
 * Bundled sidecar source. v1 is a single ESM string (esbuild output)
 * that the runtime writes to a temp file and launches with `node`. The
 * bundle is expected to import `katari-port` and call
 * `__startSidecar()` at the very end of evaluation.
 */
export type SidecarBundle = {
  /** Bundled JS source. The runtime writes this to a temp file and `node` it. */
  entry: string;
  runtime: "node";
  schemaVersion: 1;
};

// ─── IPC protocol (11 message variants, all `ipc`-prefixed) ────────────────

/** Parent (FFI Module) → Child (Sidecar). */
export type ParentToChild =
  | {
      type: "ipcDelegate";
      protocolVersion: number;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      /**
       * Same payload as `ipcDelegate` but flagged as "this was already
       * in flight before the parent restarted". User code branches on
       * `isRestored` to fail-safe (return error to avoid duplicate
       * side effects) or re-run (idempotent calls).
       */
      type: "ipcDelegateRestarted";
      protocolVersion: number;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcTerminate";
      protocolVersion: number;
      delegationId: DelegationId;
    }
  | {
      /**
       * Result for a child agent the ext started via `katari.delegate`.
       * `delegationId` is the child's id (= the one the sidecar
       * generated and sent in `ipcChildDelegate`).
       */
      type: "ipcChildDelegateAck";
      protocolVersion: number;
      delegationId: DelegationId;
      value: RawValue;
    }
  | {
      /**
       * Cancellation completion for a child agent the ext cancelled
       * via `ipcChildTerminate` (or that was killed during a parent
       * restart's cleanup pass).
       */
      type: "ipcChildTerminateAck";
      protocolVersion: number;
      delegationId: DelegationId;
    };

/** Child (Sidecar) → Parent (FFI Module). */
export type ChildToParent =
  | { type: "ipcReady"; protocolVersion: number }
  | {
      type: "ipcDelegateAck";
      protocolVersion: number;
      delegationId: DelegationId;
      value: RawValue;
    }
  | {
      type: "ipcDelegateError";
      protocolVersion: number;
      delegationId: DelegationId;
      message: string;
    }
  | {
      type: "ipcTerminateAck";
      protocolVersion: number;
      delegationId: DelegationId;
    }
  | {
      /**
       * Ext is starting a CORE-side child agent via `katari.delegate`.
       * `parentDelegationId` is the ext invocation that owns the
       * child; `delegationId` is the freshly-minted id for the child.
       */
      type: "ipcChildDelegate";
      protocolVersion: number;
      parentDelegationId: DelegationId;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      /** Ext is cancelling a child agent it previously started. */
      type: "ipcChildTerminate";
      protocolVersion: number;
      delegationId: DelegationId;
    };

// Re-exports for cross-package imports
export type { AgentDefId, DelegationId, RawValue };
