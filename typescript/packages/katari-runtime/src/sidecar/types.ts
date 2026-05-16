// Sidecar bundle + IPC protocol types.
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

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId } from "../engine/id.js";
import type { QualifiedName } from "../ir/types.js";
import type { RawValue } from "../value-codec.js";

void (null as unknown as QualifiedName); // referenced via AgentDefId encoding

/** Current wire protocol version. Bump when adding/changing a message. */
export const PROTOCOL_VERSION = 1;

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

// ─── IPC protocol (7 message variants) ─────────────────────────────────────

/** Parent (FFI Module) → Child (Sidecar). */
export type ParentToChild =
  | {
      type: "delegate";
      protocolVersion: number;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      /**
       * Same payload as `delegate` but flagged as "this was already
       * in flight before the parent restarted". User code should
       * decide per-call whether to fail-safe (return delegateError to
       * avoid duplicate side effects) or re-run (idempotent calls).
       */
      type: "delegateRestored";
      protocolVersion: number;
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      type: "terminate";
      protocolVersion: number;
      delegationId: DelegationId;
    };

/** Child (Sidecar) → Parent (FFI Module). */
export type ChildToParent =
  | { type: "ready"; protocolVersion: number }
  | {
      type: "delegateAck";
      protocolVersion: number;
      delegationId: DelegationId;
      value: RawValue;
    }
  | {
      type: "delegateError";
      protocolVersion: number;
      delegationId: DelegationId;
      message: string;
    }
  | {
      type: "terminateAck";
      protocolVersion: number;
      delegationId: DelegationId;
    };

// Re-exports for cross-package imports
export type { AgentDefId, DelegationId, RawValue };
