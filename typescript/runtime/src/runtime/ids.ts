// Branded identifier types for the runtime. Two families:
//
//   - Persistent UUIDs (project / snapshot / instance / delegation / escalation / run / blob /
//     external-call) — stable across processes, the keys of the DB tables.
//   - Engine-local integers (thread / scope / call / ask) — allocated by the engine inside an
//     instance (or, for scopes, the per-project CORE-global store). Cheap monotonic counters.
//
// Branding keeps the families from being mixed up at compile time without any runtime cost.

type Brand<T, B extends string> = T & { readonly __brand: B };

export type ProjectId = Brand<string, "ProjectId">;
export type SnapshotId = Brand<string, "SnapshotId">;
export type InstanceId = Brand<string, "InstanceId">;
export type DelegationId = Brand<string, "DelegationId">;
export type EscalationId = Brand<string, "EscalationId">;
export type RunId = Brand<string, "RunId">;
export type ExternalCallId = Brand<string, "ExternalCallId">;
export type BlobId = Brand<string, "BlobId">;

/** Unique within one instance's thread tree. */
export type ThreadId = Brand<number, "ThreadId">;
/** Unique within a project's CORE-global scope store (scopes outlive any single instance). */
export type ScopeId = Brand<number, "ScopeId">;
/** A parent's handle on one outstanding child call, unique within an instance. */
export type CallId = Brand<number, "CallId">;
/** A child's handle on one outstanding upward ask, unique within an instance. */
export type AskId = Brand<number, "AskId">;
