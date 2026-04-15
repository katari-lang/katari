import type { JsonValue } from "./json.js";

// ===========================================================================
// Ref — (endpoint, id) pair identifying a resource across servers
// ===========================================================================

export interface Ref {
  id: string;
  endpoint: string;
}

export type AgentDefRef = Ref;
export type AgentRef = Ref;
export type DelegationRef = Ref;
export type TemplateRef = Ref;
export type CapabilityRef = Ref;
export type EscalationRef = Ref;

// ===========================================================================
// Resources
// ===========================================================================

export type AgentStatus = "RUNNING" | "TERMINATING";

/** Agent Definition — immutable definition of an agent type */
export interface AgentDefinition {
  id: string;
  endpoint: string;
  name: string;
  description?: string;
  input_schema: JsonValue;
  output_schema: JsonValue;
  template_refs?: TemplateRef[];
}

/** Agent — a running instance of an AgentDefinition */
export interface Agent {
  id: string;
  endpoint: string;
  input: JsonValue;
  definition_ref: AgentDefRef;
  delegation_ref: DelegationRef | null;
  status: AgentStatus;
}

/** Delegation — proof that a parent agent spawned a child. Managed by parent's server. */
export interface Delegation {
  id: string;
  endpoint: string;
  agent_def_ref: AgentDefRef;
  input: JsonValue;
  capability_refs: CapabilityRef[];
}

/** Template — effect definition (like algebraic effects). Describes an escalation shape. */
export interface Template {
  id: string;
  endpoint: string;
  name: string;
  description?: string;
  input_schema: JsonValue;
  output_schema: JsonValue;
}

/** Capability — an agent's ability to handle escalations for a specific template */
export interface Capability {
  id: string;
  endpoint: string;
  template_ref: TemplateRef;
  agent_ref: AgentRef;
}

/** Escalation — a child's request to a specific capability. Managed by child's server. */
export interface Escalation {
  id: string;
  endpoint: string;
  capability_ref: CapabilityRef;
  input: JsonValue;
}

// ===========================================================================
// POST /delegate
// ===========================================================================

export interface DelegateRequest {
  agent_def_ref: AgentDefRef;
  input: JsonValue;
  delegation_ref: DelegationRef | null;
  capability_refs: CapabilityRef[];
}

export interface DelegateResponse {
  agent_ref: AgentRef;
}

// ===========================================================================
// POST /delegate_ack
// ===========================================================================

export interface DelegateAckRequest {
  delegation_ref: DelegationRef;
  output: JsonValue;
}

// ===========================================================================
// POST /escalate
// ===========================================================================

export interface EscalateRequest {
  escalation_ref: EscalationRef;
  capability_ref: CapabilityRef;
  input: JsonValue;
}

// ===========================================================================
// POST /escalate_ack
// ===========================================================================

export interface EscalateAckRequest {
  escalation_ref: EscalationRef;
  output: JsonValue;
}

// ===========================================================================
// POST /terminate
// ===========================================================================

export interface TerminateRequest {
  delegation_ref: DelegationRef;
}

// ===========================================================================
// POST /terminate_ack
// ===========================================================================

export interface TerminateAckRequest {
  delegation_ref: DelegationRef;
}

// ===========================================================================
// POST /throw
// ===========================================================================

export interface ThrowRequest {
  delegation_ref: DelegationRef;
  message: string;
}

// ===========================================================================
// Common responses
// ===========================================================================

export interface SuccessResponse {
  success: boolean;
}

export interface ErrorResponse {
  error: string;
}

// ===========================================================================
// Outgoing messages — actions that a server needs to send to other servers
// ===========================================================================

export interface OutgoingMessage {
  toEndpoint: string;
  kind: OutgoingKind;
}

export type OutgoingKind =
  | { type: "Delegate"; body: DelegateRequest; delegationId: string }
  | { type: "DelegateAck"; body: DelegateAckRequest }
  | { type: "Escalate"; body: EscalateRequest }
  | { type: "EscalateAck"; body: EscalateAckRequest }
  | { type: "Terminate"; body: TerminateRequest }
  | { type: "TerminateAck"; body: TerminateAckRequest }
  | { type: "Throw"; body: ThrowRequest };
