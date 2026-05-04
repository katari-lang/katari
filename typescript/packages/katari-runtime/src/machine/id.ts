/** Opaque runtime identifiers. Branded string types for type safety. */

export type ThreadId = string & { readonly __brand: "ThreadId" };
export type ScopeId = string & { readonly __brand: "ScopeId" };
export type DelegationId = string & { readonly __brand: "DelegationId" };
export type EscalationId = string & { readonly __brand: "EscalationId" };

export function newThreadId(): ThreadId {
  return crypto.randomUUID() as ThreadId;
}

export function newScopeId(): ScopeId {
  return crypto.randomUUID() as ScopeId;
}

export function newDelegationId(): DelegationId {
  return crypto.randomUUID() as DelegationId;
}
