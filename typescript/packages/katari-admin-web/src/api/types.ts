// Wire-format types for the admin web client. These mirror the shapes
// served by katari-api-server's HTTP layer. Keeping a local mirror (rather
// than importing from @katari-lang/api-server) keeps this package
// browser-only with no server dependencies.

import type { AgentDefinition, RawValue, SchemaBundle } from "@katari-lang/runtime";

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
  /** One-line summary from `katari.toml`. `null` if the operator hasn't
   *  set `[package].description`. */
  description: string | null;
  /** Long-form README markdown, picked up from `README.md` next to
   *  `katari.toml` at `apply` time. `null` if the file is absent. */
  readme: string | null;
  createdAt: string;
};

export type SnapshotSummary = {
  id: SnapshotId;
  projectId: ProjectId;
  /** Display label. The server always fills a default when the operator
   *  omits `--message`, so this is never empty. */
  message: string;
  createdAt: string;
};

export type Snapshot = {
  id: SnapshotId;
  projectId: ProjectId;
  irModule: unknown;
  sidecarBundle: {
    entry: string;
    runtime: "node";
    schemaVersion: number;
  } | null;
  schemaBundle: SchemaBundle;
  message: string;
  createdAt: string;
};

/**
 * Operator-visible run state. A "run" is an ApiModule-launched root
 * delegation; terminal states (`cancelled / succeeded / error`) live in
 * the `runs_audit` table and survive the live `delegations` row being
 * deleted on the terminal ack.
 */
export type RunState = "running" | "cancelling" | "cancelled" | "succeeded" | "error";

export type CancelReason = "user" | "error";

export type RunRowWire = {
  id: RunId;
  snapshotId: SnapshotId;
  /** Display label. The server always fills a default when the operator
   *  omits one, so this is never empty. */
  name: string;
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

/** The `$ref as:file` envelope a `file`-typed argument expects. Built
 *  server-side (the client never needs to know a file's storage module),
 *  so it drops straight into a run's args as a `RawValue`. */
export type FileRef = {
  $ref: { module: "api"; id: string };
  as: "file";
  hash: string;
  size: number;
  contentType?: string;
};

/** A persistent project file (`api_files`) plus its ready-to-use ref. */
export type FileWire = {
  id: string;
  hash: string;
  size: number;
  contentType?: string;
  displayName?: string;
  createdAt: string;
  ref: FileRef;
};

export type AgentWire = AgentDefinition;

/**
 * Generic paginated response. Server returns `nextCursor: null` when
 * there are no more items.
 */
export type PaginatedResponse<K extends string, T> = {
  [key in K]: T[];
} & { nextCursor: string | null };

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
  /** Present on the root node (= the run itself); always non-empty.
   *  Absent on non-root delegations. */
  name?: string;
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
