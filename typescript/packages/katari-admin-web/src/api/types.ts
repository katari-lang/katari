// Wire-format types for the admin web client. These mirror the shapes
// served by katari-api-server's HTTP layer. Keeping a local mirror (rather
// than importing from @katari-lang/api-server) keeps this package
// browser-only with no server dependencies.

import type { RawValue, SchemaBundle, AgentDefinition } from "@katari-lang/runtime";

export type ProjectId = string;
export type SnapshotId = string;
export type AgentId = string;
export type EscalationId = string;

export type Project = {
  id: ProjectId;
  name: string;
  createdAt: string;
};

export type SnapshotSummary = {
  id: SnapshotId;
  projectId: ProjectId;
  createdAt: string;
};

export type Snapshot = {
  id: SnapshotId;
  projectId: ProjectId;
  irModule: unknown;
  sidecarBundle: { entry: string; runtime: "node"; schemaVersion: number } | null;
  schemaBundle: SchemaBundle;
  createdAt: string;
};

export type AgentState =
  | "running"
  | "cancelling"
  | "cancelled"
  | "succeeded"
  | "error";

export type AgentRowWire = {
  id: AgentId;
  delegationId: string;
  snapshotId: SnapshotId;
  qualifiedName: string;
  args: Record<string, RawValue>;
  state: AgentState;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
};

export type EscalationState = "open" | "answered" | "cancelled";

// Mirrors api-server's `ApiPendingEscalationWire` exactly: see
// typescript/packages/katari-api-server/src/wire/agent-wire.ts.
// `agentDefId` is the flat string the API module knows the agent by
// (= a qualified name for top-level agents, or `closure:<id>` for
// dynamically-allocated closures). No `updatedAt` field — the wire
// only carries the row's createdAt.
export type EscalationWire = {
  escalationId: EscalationId;
  delegationId: string;
  snapshotId: SnapshotId;
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
