// Sidecar bundle + IPC protocol types.
//
// **Sidecar**: subprocess that the FFI Runner spawns per snapshot. The
// user's bundled JS (built with the Katari CLI + `katari-port`) runs
// inside, receives `ParentToChild` over stdin, and responds with
// `ChildToParent` over stdout (one JSON object per line). stderr is
// passed through to the parent for log output.
//
// 11 message variants, all `ipc`-prefixed so log lines and switch arms
// read distinguishably from bus event kinds. Escalate / log / shutdown
// are deliberately not on the wire — FfiModule relays escalate on the
// bus, console.* is redirected to stderr, and graceful shutdown uses
// SIGTERM → SIGKILL. The wire is still pre-publish, so there's no
// `protocolVersion` field; readers fail-fast on unknown `type` values.

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId } from "../engine/id.js";
import type { QualifiedName } from "../ir/types.js";
import type { RawValue } from "../value-codec.js";

void (null as unknown as QualifiedName); // referenced via AgentDefId encoding

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
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      type: "ipcTerminate";
      delegationId: DelegationId;
    }
  | {
      /**
       * Result for a child agent the ext started via `katari.delegate`.
       * `delegationId` is the child's id (= the one the sidecar
       * generated and sent in `ipcChildDelegate`).
       */
      type: "ipcChildDelegateAck";
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
      delegationId: DelegationId;
    };

/** Child (Sidecar) → Parent (FFI Module). */
export type ChildToParent =
  | { type: "ipcReady" }
  | {
      type: "ipcDelegateAck";
      delegationId: DelegationId;
      value: RawValue;
    }
  | {
      type: "ipcDelegateError";
      delegationId: DelegationId;
      message: string;
    }
  | {
      type: "ipcTerminateAck";
      delegationId: DelegationId;
    }
  | {
      /**
       * Ext is starting a CORE-side child agent via `katari.delegate`.
       * `parentDelegationId` is the ext invocation that owns the
       * child; `delegationId` is the freshly-minted id for the child.
       */
      type: "ipcChildDelegate";
      parentDelegationId: DelegationId;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      /** Ext is cancelling a child agent it previously started. */
      type: "ipcChildTerminate";
      delegationId: DelegationId;
    };

// Re-exports for cross-package imports
export type { AgentDefId, DelegationId, RawValue };
