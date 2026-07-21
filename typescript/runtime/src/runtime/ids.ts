// Branded identifier types for the runtime. Two families:
//
//   - Persistent UUIDs (project / snapshot / instance / delegation / escalation / run / blob) —
//     stable across processes, the keys of the DB tables.
//   - Engine-local integers (thread / scope / call / ask) — allocated by the engine inside an
//     instance (or, for scopes, the per-project CORE-global store). Cheap monotonic counters.
//
// Branding keeps the families from being mixed up at compile time without any runtime cost.

type Brand<T, B extends string> = T & { readonly __brand: B };

export type ProjectId = Brand<string, "ProjectId">;
export type SnapshotId = Brand<string, "SnapshotId">;
/** Content hash of one module's IR (hex SHA-256 of its canonical serialisation): the key of the
 *  content-addressed module store and the value a snapshot's manifest maps each module name to.
 *  Computed by the CLI (`Katari.Project.Upload.hashModule`) and treated as an opaque key here. */
export type ModuleHash = Brand<string, "ModuleHash">;

/** Brand a wire-supplied string as a `ModuleHash`. The runtime trusts the CLI's hash as an opaque
 *  key (it does not recompute it), so this is the single boundary cast. */
export const toModuleHash = (value: string): ModuleHash => value as ModuleHash;

/** Brand a wire-supplied string as a `SnapshotId`. A callable value round-trips its snapshot through the
 *  JSON boundary (a `$katari_agent` / `$katari_closure` reference carries it), so the codec re-brands it on the way in. */
export const toSnapshotId = (value: string): SnapshotId => value as SnapshotId;
export type InstanceId = Brand<string, "InstanceId">;
export type DelegationId = Brand<string, "DelegationId">;
export type EscalationId = Brand<string, "EscalationId">;
// A run has no id family of its own: a run IS its permanent api-side instance, so a run id is an
// `InstanceId` (`runs.id` = that instance's id) — see the ApiReactor.
export type BlobId = Brand<string, "BlobId">;
/** The id of one durable outbox row — a produced-but-not-yet-consumed external event (the transactional
 *  outbox backing the actor's mailbox, so an in-flight event survives a crash). */
export type OutboxSeq = Brand<string, "OutboxSeq">;

/** Mint a fresh persistent UUID. The branded wrappers below keep the families distinct at the call site. */
const newUuid = (): string => crypto.randomUUID();

export const newInstanceId = (): InstanceId => newUuid() as InstanceId;
export const newDelegationId = (): DelegationId => newUuid() as DelegationId;

/** Brand a wire-supplied string as a `DelegationId`. The FFI sidecar echoes back the delegation it was
 *  dispatched under as a plain string; this is the single boundary cast that re-brands it on the way in. */
export const toDelegationId = (value: string): DelegationId => value as DelegationId;

/** The id of a project's one `api` management root. It IS the project id — there is exactly one root per
 *  project, so the project id is its single source of truth: stable across restarts, derivable in any
 *  layer, needing no registry. This is the one place the project / instance id families deliberately
 *  coincide (mirrors the prototype's `project-root entity id = projectId`). */
export const apiRootIdOf = (projectId: ProjectId): InstanceId => projectId as string as InstanceId;

export const newEscalationId = (): EscalationId => newUuid() as EscalationId;
export const newBlobId = (): BlobId => newUuid() as BlobId;
export const newOutboxSeq = (): OutboxSeq => newUuid() as OutboxSeq;

/** Unique within one instance's thread tree. */
export type ThreadId = Brand<number, "ThreadId">;
/** Unique within a project's CORE-global scope store (scopes outlive any single instance). */
export type ScopeId = Brand<number, "ScopeId">;
/** A parent's handle on one outstanding child call, unique within an instance. */
export type CallId = Brand<number, "CallId">;
/** A child's handle on one outstanding upward ask, unique within an instance. */
export type AskId = Brand<number, "AskId">;

// Brand a monotonic counter value into its engine-local integer id. The counters live on the instance
// (thread / call / ask) and the per-project store (scope); these are the single boundary casts.
export const toThreadId = (value: number): ThreadId => value as ThreadId;
export const toScopeId = (value: number): ScopeId => value as ScopeId;
export const toCallId = (value: number): CallId => value as CallId;
export const toAskId = (value: number): AskId => value as AskId;
