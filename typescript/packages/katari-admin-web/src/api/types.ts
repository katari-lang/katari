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
 * Operator-visible run state (Entity model). A "run" is the API's per-run
 * record; its state reflects the run's CORE-root child. Terminal is `done`
 * (success) or `error` (a user cancel ends as `error` with cancelReason=user).
 */
export type RunState = "running" | "cancelling" | "done" | "error";

export type CancelReason = "user" | "error";

export type RunRowWire = {
  id: RunId;
  projectId: ProjectId;
  snapshotId: SnapshotId;
  /** The `D` the run-root issued to the CORE root (internal handle). */
  coreDelegationId: DelegationId;
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

/** An operator-facing escalation is `open` (awaiting an answer) or `answered`.
 *  (Cancelled ones are dropped — they die with their raiser entity.) */
export type EscalationState = "open" | "answered";

// Mirrors api-server's `RunEscalationWire` (the API's per-run operator view):
// see typescript/packages/katari-api-server/src/wire/agent-wire.ts. The live
// `escalations` row is CORE's (raiser-owned); this is the API's record, keyed by
// the run it belongs to. `agentDefId` is the requested capability's qname.
export type EscalationWire = {
  runId: RunId;
  escalationId: EscalationId;
  agentDefId: string;
  args: Record<string, RawValue>;
  state: EscalationState;
  /** The answer, present once `state === "answered"`. */
  value?: RawValue;
  createdAt: string;
  answeredAt?: string;
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

// ─── Run tree (live entity view) ──────────────────────────────────────────

export type EntityModule = "core" | "ffi" | "api" | "env";

// Mirrors api-server's `RunTreeNode` (entity-tree-service): the execution
// entity forest under a run. The root node carries the Run's terminal state.
export type RunTreeNode = {
  entityId: string;
  /** The summoning delegation `D` (null only for the project/run root). */
  delegationId: string | null;
  parentEntityId: string | null;
  module: EntityModule;
  agentDefId: string | null;
  qualifiedName: string | null;
  /** The entity's state for inner nodes; the Run's state for the root. */
  state: RunState;
  /** Present on the root node (= the run itself). */
  name?: string;
  cancelReason?: CancelReason | null;
  args: Record<string, RawValue>;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  children: RunTreeNode[];
};

export type RunTree = {
  root: RunTreeNode;
  resolvedAt: string;
};
