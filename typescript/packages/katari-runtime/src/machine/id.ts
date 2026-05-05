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

/**
 * AskId identifies a single in-flight `request` from one asker thread.
 *
 * Symmetric to {@link CallId}: while CallId is the parent's slot for
 * tracking a child call, AskId is the asker's slot for tracking one
 * in-flight ask. The **asker** allocates the AskId; the boundary
 * (HandleThread) tracks it as part of `(asker, askId)` and echoes both
 * back in `askComplete` so the asker can match the response.
 *
 * Per-asker counter (not global), so the (asker, askId) pair is unique.
 * RequestThread can only ask once in its lifetime so it just uses 0.
 * Future askers that may issue multiple asks (e.g., an external agent
 * with its own connection) will allocate per-instance.
 */
export type AskId = number & { readonly __brand: "AskId" };

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
