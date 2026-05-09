// Branded id types used throughout the engine.
//
// All ids are opaque strings (UUIDs) created via `crypto.randomUUID()`. The
// brand prevents accidental cross-assignment between id namespaces.
//
// `AskId` is a per-thread counter (asker-local), not a UUID — it only needs
// to be unique within one thread's lifetime.

export type ThreadId = string & { readonly __brand: "ThreadId" };
export type ScopeId = string & { readonly __brand: "ScopeId" };
export type DelegationId = string & { readonly __brand: "DelegationId" };
export type EscalationId = string & { readonly __brand: "EscalationId" };

/**
 * ClosureId: machine-local identifier for a closure record stored in
 * `state.closures`. Allocated by `statementMakeClosure` execution. Closures
 * are first-class runtime objects (rather than inlined into `Value`) so
 * agent calls via closure can reference them by id, and so the GC can
 * collect them when no live `Value` holds a closure reference.
 */
export type ClosureId = number & { readonly __brand: "ClosureId" };

/**
 * AskId: per-asker counter that pairs an `ask` with its eventual `askAck`.
 * The asker allocates the AskId (typically `0, 1, 2, ...`); proxy threads
 * also allocate their own AskIds when forwarding asks upwards (see
 * `Thread.askIdMap` in `engine/thread/types.ts`).
 */
export type AskId = number & { readonly __brand: "AskId" };

/** CallId: parent-local index identifying a specific child call. */
export type CallId = number & { readonly __brand: "CallId" };

export function createThreadId(): ThreadId {
  return crypto.randomUUID() as ThreadId;
}

export function createScopeId(): ScopeId {
  return crypto.randomUUID() as ScopeId;
}

export function createDelegationId(): DelegationId {
  return crypto.randomUUID() as DelegationId;
}

export function createEscalationId(): EscalationId {
  return crypto.randomUUID() as EscalationId;
}
