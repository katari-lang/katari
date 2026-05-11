// Sidecar bundle + IPC protocol types.
//
// **Sidecar**: subprocess that the FFI Runner spawns per snapshot. The
// user's bundled JS runs inside, receives IPC messages over stdio, and
// responds through stdout. CLI bundles user code (esbuild) into `entry`
// before upload.

import type { AgentDefId } from "../agent-def-id.js";
import type { DelegationId, EscalationId } from "../engine/id.js";
import type { QualifiedName } from "../ir/types.js";
import type { RawValue } from "../value-codec.js";

void (null as unknown as QualifiedName); // referenced via AgentDefId encoding

/**
 * Bundled sidecar source. v1 is a single JS string (esbuild output) that
 * gets eval'd by the bootstrapper. Future versions can add multi-file or
 * external deps.
 */
export type SidecarBundle = {
  /** Bundled JS source. The bootstrapper requires it as a CommonJS module. */
  entry: string;
  runtime: "node";
  schemaVersion: 1;
};

// ─── IPC protocol ──────────────────────────────────────────────────────────
//
// Wire format: 1 line of JSON per message on stdin / stdout. (Sidecar's
// stderr is logged by the parent, not parsed.)

/** Parent (FFI Module) → Child (Sidecar). */
export type ParentToChild =
  | {
      /** Fresh invocation. User code runs side effects normally. */
      type: "delegate";
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      /**
       * Restored invocation after a parent restart. Carries the same
       * payload as `delegate` but signals "this was already in flight
       * before the parent crashed". User code should decide per-call
       * whether to (a) fail-safe (return delegateError to avoid
       * duplicate side effects on non-idempotent calls) or (b) re-run
       * (idempotent calls that can be safely re-executed).
       *
       * Sidecar itself is stateless across restarts — only the FFI
       * Module persists in-flight delegations. Routing this as a
       * dedicated event lets user code branch on intent without the
       * Module needing to know per-call idempotency.
       */
      type: "restoredDelegate";
      delegationId: DelegationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | { type: "terminate"; delegationId: DelegationId }
  | { type: "escalateAck"; escalationId: EscalationId; value: RawValue }
  | { type: "escalateError"; escalationId: EscalationId; message: string }
  | { type: "shutdown" };

/** Child (Sidecar) → Parent (FFI Runner). */
export type ChildToParent =
  | { type: "ready" }
  | {
      type: "delegateAck";
      delegationId: DelegationId;
      value: RawValue;
    }
  | {
      type: "delegateError";
      delegationId: DelegationId;
      message: string;
    }
  | { type: "terminateAck"; delegationId: DelegationId }
  | {
      type: "escalate";
      delegationId: DelegationId;
      escalationId: EscalationId;
      agentDefId: AgentDefId;
      args: Record<string, RawValue>;
    }
  | {
      type: "log";
      level: "debug" | "info" | "warn" | "error";
      message: string;
      context?: Record<string, unknown>;
    };

// Re-exports for cross-package imports
export type { AgentDefId, DelegationId, EscalationId, RawValue };
