/** Opaque runtime identifiers. Branded string types for type safety. */

export type ThreadId = string & { readonly __brand: "ThreadId" };
export type ScopeId = string & { readonly __brand: "ScopeId" };
/**
 * DelegationId represents a unique delegation instance.
 * This instance is created by an endpoint that "delegates" work to the other endpoint
 */
export type DelegationId = string & { readonly __brand: "DelegationId" };
/**
 * EscalationId represents a unique escalation instance.
 * This instance is created by an endpoint that "escalates" work to the other endpoint
 */
export type EscalationId = string & { readonly __brand: "EscalationId" };

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
