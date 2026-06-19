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
export type InstanceId = Brand<string, "InstanceId">;
export type DelegationId = Brand<string, "DelegationId">;
export type EscalationId = Brand<string, "EscalationId">;
export type RunId = Brand<string, "RunId">;
export type BlobId = Brand<string, "BlobId">;

/** Unique within one instance's thread tree. */
export type ThreadId = Brand<number, "ThreadId">;
/** Unique within a project's CORE-global scope store (scopes outlive any single instance). */
export type ScopeId = Brand<number, "ScopeId">;
/** A parent's handle on one outstanding child call, unique within an instance. */
export type CallId = Brand<number, "CallId">;
/** A child's handle on one outstanding upward ask, unique within an instance. */
export type AskId = Brand<number, "AskId">;
