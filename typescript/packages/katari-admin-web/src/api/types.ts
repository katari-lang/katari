// Wire-format types for the admin web client. These mirror the shapes
// served by katari-api-server's HTTP layer. Keeping a local mirror (rather
// than importing from @katari-lang/api-server) keeps this package
// browser-only with no server dependencies.

import type { RawValue, SchemaBundle, AgentDefinition } from "@katari-lang/runtime";

export type ProjectId = string;
export type SnapshotId = string;
/** A run id is the root delegation's uuid; identical encoding. */
export type RunId = string;
/** Generic delegation id (root or child). */
export type DelegationId = string;
export type EscalationId = string;

export type Project = {
  id: ProjectId;
  name: string;
  createdAt: string;
};

export type SnapshotSummary = {
  id: SnapshotId;
  projectId: ProjectId;
  message: string | null;
  createdAt: string;
};

export type Snapshot = {
  id: SnapshotId;
  projectId: ProjectId;
  irModule: unknown;
  sidecarBundle: { entry: string; runtime: "node"; schemaVersion: number } | null;
  schemaBundle: SchemaBundle;
  message: string | null;
  createdAt: string;
};

/**
 * Operator-visible run state. A "run" is an ApiModule-launched root
 * delegation; terminal states (`cancelled / succeeded / error`) live in
 * the `runs_audit` table and survive the live `delegations` row being
 * deleted on the terminal ack.
 */
export type RunState =
  | "running"
  | "cancelling"
  | "cancelled"
  | "succeeded"
  | "error";

export type CancelReason = "user" | "error";

export type RunRowWire = {
  id: RunId;
  snapshotId: SnapshotId;
  /** Operator-supplied label. `null` when unnamed. */
  name: string | null;
  qualifiedName: string;
  args: Record<string, RawValue>;
  state: RunState;
  cancelReason: CancelReason | null;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  completedAt?: string;
};

export type EscalationState = "open" | "answered" | "cancelled";

// Mirrors api-server's `EscalationRowWire`: see
// typescript/packages/katari-api-server/src/wire/agent-wire.ts.
// `agentDefId` is the flat string the issuing module knows the agent
// by (= a qualified name for top-level agents). No `updatedAt` field —
// the wire only carries the row's createdAt.
export type EscalationWire = {
  id: EscalationId;
  delegationId: DelegationId;
  rootDelegationId: DelegationId;
  snapshotId: SnapshotId;
  callerEndpoint: string;
  receiverEndpoint: string;
  agentDefId: string;
  args: Record<string, RawValue>;
  state: EscalationState;
  value?: RawValue;
  createdAt: string;
};

export type EnvEntry = {
  key: string;
  value: string;
  isSecret: boolean;
  updatedAt: string;
};

export type AgentDefinitionWire = AgentDefinition;

// ─── Delegation tree (live view) ──────────────────────────────────────────

export type DelegationTreeNode = {
  delegationId: DelegationId;
  parentDelegationId: DelegationId | null;
  rootDelegationId: DelegationId;
  callerEndpoint: string;
  ownerEndpoint: string;
  agentDefId: string;
  qualifiedName: string | null;
  state: "running" | "cancelling" | "cancelled" | "error" | "succeeded";
  name?: string | null;
  cancelReason?: CancelReason | null;
  args: Record<string, RawValue>;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  children: DelegationTreeNode[];
};

export type DelegationTree = {
  root: DelegationTreeNode;
  resolvedAt: string;
};
