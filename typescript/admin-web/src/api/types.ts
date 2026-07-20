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

/** How a surface should render an open escalation. The runtime folds the request-name sniff into this
 *  sum once at its service boundary, so each surface only dispatches on `kind`: a schema-driven answer
 *  form (the answer schema rides here, or `null` when the request is unanswerable), or an OAuth
 *  authorization the runtime hosts (answered out-of-band by its callback, never by a posted value). The
 *  oauth `url` is the server a run paused on (an mcp credential); it is `null` for a configured credential,
 *  which authenticates against an operator-registered client and so names no server (a genuine absence). */
export type EscalationPresentation =
  | { kind: "form"; answerSchema: JsonSchema | null }
  | { kind: "oauth"; name: string; url: string | null };

export interface Escalation {
  id: string;
  request: string;
  argument: Json;
  runId: string;
  createdAt: string;
  presentation: EscalationPresentation;
}

export interface RunEscalationAudit {
  escalationId: string;
  question: Json;
  answer: Json;
  answeredAt: string;
}

/** One stored OAuth credential, as the admin API lists it: metadata only (the token material is
 *  write-only — it enters through the runtime-hosted flow, never the API). `profile` is the acquisition
 *  discriminant the runtime returns — the page dispatches on IT, never on a name-match heuristic: a
 *  `configured` credential re-authorizes directly against its registered client, an `mcp` one prompts
 *  for its server URL. */
export interface Credential {
  name: string;
  profile: "mcp" | "configured";
  updatedAt: string;
}

/** One operator-registered OAuth client, as the registry lists it. `hasSecret` says whether a secret is
 *  stored WITHOUT revealing it — the secret is write-only over the API. `authorizationParameters` (extra
 *  provider-specific authorize-URL parameters, e.g. Google's `access_type=offline`) is plain
 *  configuration, readable both ways. */
export interface OauthClient {
  name: string;
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  hasSecret: boolean;
  scopes: string[];
  authorizationParameters: Record<string, string>;
}

/** A PUT registering (or replacing) an OAuth client — a full replace of the plain fields, with three-way
 *  secret semantics (the secret is write-only, so a re-register cannot echo it back): a present
 *  `clientSecret` stores a new one, an ABSENT one keeps whatever is stored (nothing on a fresh
 *  registration — a public client), and `clearSecret` is the explicit downgrade to public. Never send
 *  both. */
export interface OauthClientInput {
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  clientSecret?: string;
  clearSecret: boolean;
  scopes: string[];
  authorizationParameters: Record<string, string>;
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

/** The runtime's reactor names — every kind an instance / delegation edge / trace event can carry
 *  (mirrors the runtime's `ReactorName`). One alias so a new reactor is a single edit here. */
export type ReactorKind = "core" | "api" | "ffi" | "http" | "webhook" | "mcp" | "time" | "oauth";

export interface TreeInstance {
  id: string;
  kind: ReactorKind;
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
  reactor: ReactorKind;
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
  from: ReactorKind;
  to: ReactorKind;
  delegationId: string;
  escalationId: string | null;
  target: TreeTarget | null;
  ask: string | null;
  request: string | null;
  payload: Json;
  summary: string;
  createdAt: string;
}

/** The six external-event kinds a trace is made of — the trace `kind` filter's domain. */
export const RUN_EVENT_KINDS = [
  "delegate",
  "delegateAck",
  "escalate",
  "escalateAck",
  "terminate",
  "terminateAck",
] as const satisfies readonly RunEvent["kind"][];

/** The events endpoint's payload: one page of the trace, with the run's state riding along so a single
 *  poll both extends the trace and answers "is it still running". `total` = the filtered event count
 *  (for the pager); it is present only on an offset browse (the console's mode) — a keyset tail
 *  (`after`) omits it, since counting the whole run on every poll would be wasted work. */
export interface RunEventsPage {
  state: RunState;
  events: RunEvent[];
  total?: number;
}

/** A page of a listing whose total rides on the `X-Total-Count` header (runs / snapshots / files). */
export interface Page<T> {
  items: T[];
  total: number;
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

export interface StoreEntrySummary {
  key: string;
  updatedAt: string;
}

/** One store entry's value as redacting wire JSON (a private node reads as `$katari_redacted`). */
export interface StoreEntryDetail {
  key: string;
  value: Json;
}

export interface Health {
  status: string;
  uptimeSeconds: number;
}
