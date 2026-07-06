// Wire types of the runtime API (base /api/v1). These mirror the runtime's module services; the
// envelope is `{ ok: true, data } | { ok: false, error }` and is unwrapped by the client.

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };

/** A JSON Schema document as the runtime serves it (Draft 2020-12 canonical shapes). */
export type JsonSchema = { [keyword: string]: Json };

export interface Project {
  id: string;
  name: string;
  description: string | null;
  readme: string | null;
  headSnapshotId: string | null;
  createdAt: string;
}

/** The list endpoint serves summary rows; the module manifest travels only on head / detail reads. */
export interface SnapshotSummary {
  id: string;
  message: string;
  createdAt: string;
}

/** `snapshots/head` degrades to all-null fields while the project has no deploy yet. */
export interface HeadSnapshot {
  id: string | null;
  message: string | null;
  modules: Record<string, string>;
  createdAt: string | null;
}

export type RunState = "running" | "cancelling" | "done" | "error" | "cancelled";

export interface Run {
  id: string;
  name: string;
  qualifiedName: string;
  snapshotId: string | null;
  state: RunState;
  argument: Json;
  result: Json;
  errorMessage: string | null;
  cancelReason: string | null;
  createdAt: string;
  completedAt: string | null;
}

export interface Escalation {
  id: string;
  request: string;
  argument: Json;
  runId: string;
  createdAt: string;
  answerSchema: JsonSchema | null;
}

export interface RunEscalationAudit {
  escalationId: string;
  question: Json;
  answer: Json;
  answeredAt: string;
}

/** What a delegation-tree node's instance runs, as the runtime projects it for display. */
export type TreeTarget =
  | { kind: "agent"; name: string }
  | { kind: "closure"; blockId: number; module: string }
  | { kind: "external"; key: string };

export interface TreeEscalation {
  id: string;
  request: string;
  /** Whether this leg is the api-addressed one (the answer surface accepts it) or a relay hop. */
  answerable: boolean;
  createdAt: string;
}

export interface TreeInstance {
  id: string;
  kind: "core" | "api" | "ffi" | "http";
  status: "running" | "cancelling" | "awaitingAnswer";
  target: TreeTarget | null;
  snapshotId: string | null;
  openEscalations: TreeEscalation[];
  children: DelegationTreeNode[];
}

/** One live delegation edge; `instance` is null while the delegate is still in flight. */
export interface DelegationTreeNode {
  delegationId: string;
  state: "running" | "cancelling";
  reactor: "core" | "api" | "ffi" | "http";
  createdAt: string;
  instance: TreeInstance | null;
}

/** The tree endpoint's payload — the rows are live routing, so a terminal run's tree is null. */
export interface RunTree {
  state: RunState;
  tree: DelegationTreeNode | null;
}

/** One event of a run's execution trace (the journaled external events, oldest first). `target` is set
 *  for a `delegate`, `ask` / `request` for an `escalate`; `payload` is the redacted value the event
 *  carried (`null` on the terminate legs); `summary` is the server-rendered one-liner the CLI prints. */
export interface RunEvent {
  seq: number;
  kind: "delegate" | "delegateAck" | "escalate" | "escalateAck" | "terminate" | "terminateAck";
  from: "core" | "api" | "ffi" | "http";
  to: "core" | "api" | "ffi" | "http";
  delegationId: string;
  escalationId: string | null;
  target: TreeTarget | null;
  ask: string | null;
  request: string | null;
  payload: Json;
  summary: string;
  createdAt: string;
}

/** The events endpoint's payload: one page of the trace, with the run's state riding along so a single
 *  poll both extends the trace and answers "is it still running". */
export interface RunEventsPage {
  state: RunState;
  events: RunEvent[];
}

export interface AgentEntry {
  qualifiedName: string;
  input: JsonSchema;
  output: JsonSchema;
  /** The agent's `@"..."` doc annotation; empty string when undocumented. */
  description: string;
}

export interface AgentList {
  snapshotId: string;
  agents: AgentEntry[];
}

export interface AgentDetail {
  snapshotId: string;
  qualifiedName: string;
  input: JsonSchema;
  output: JsonSchema;
  /** The agent's `@"..."` doc annotation; empty string when undocumented. */
  description: string;
}

export interface FileEntry {
  id: string;
  hash: string;
  size: number;
  contentType: string | null;
  semanticKind: string;
}

export interface EnvEntry {
  key: string;
  isSecret: boolean;
  updatedAt: string;
}

export type EnvEntryDetail =
  | { key: string; isSecret: true; updatedAt: string }
  | { key: string; isSecret: false; value: string; updatedAt: string };

export interface Health {
  status: string;
  uptimeSeconds: number;
}
