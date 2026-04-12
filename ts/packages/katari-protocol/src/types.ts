import type { JsonValue } from "./json.js";

// ===========================================================================
// GET /request
// ===========================================================================

export interface RequestInfo {
  request_id: string;
  request_where: string;
  name: string;
  description: string;
  arg_types: JsonValue[];
  return_type: JsonValue;
}

// ===========================================================================
// GET /agent_def
// ===========================================================================

export interface AgentDefInfo {
  agent_def_id: string;
  agent_def_where: string;
  name: string;
  description: string;
  arg_types: JsonValue[];
  return_type: JsonValue;
  with_effects: string[];
}

// ===========================================================================
// GET /agent
// ===========================================================================

export interface AgentSummary {
  agent_id: string;
  agent_where: string;
  agent_def_id: string;
  args: JsonValue[];
}

// ===========================================================================
// GET /agent/:agent_id
// ===========================================================================

export interface AgentDetail {
  agent_id: string;
  agent_where: string;
  agent_def_id: string;
  args: JsonValue[];
  parent_agent_id: string;
  parent_agent_where: string;
  with_effects: string[];
  child_agents: ChildAgentRef[];
}

export interface ChildAgentRef {
  agent_id: string;
  agent_where: string;
}

// ===========================================================================
// POST /agent (spawn)
// ===========================================================================

export interface SpawnAgentRequest {
  agent_def_id: string;
  args: JsonValue[];
  parent_agent_id: string;
  parent_agent_where: string;
  with_effects?: string[];
  call_stack?: CallStackEntry[];
}

export interface CallStackEntry {
  agent_def_id: string;
  agent_def_where: string;
  agent_def_name: string;
}

export interface SpawnAgentResponse {
  agent_id: string;
  agent_where: string;
}

// ===========================================================================
// POST /agent/request
// ===========================================================================

export interface AgentRequestBody {
  request_id: string;
  request_def_id: string;
  request_def_where: string;
  args: JsonValue[];
  from_agent_id: string;
  from_agent_where: string;
}

// ===========================================================================
// POST /agent/reply
// ===========================================================================

export interface AgentReplyBody {
  request_id: string;
  result: JsonValue;
  from_agent_id: string;
  from_agent_where: string;
  agent_id: string;
}

// ===========================================================================
// POST /agent/return
// ===========================================================================

export interface AgentReturnBody {
  result: JsonValue;
  from_agent_id: string;
  from_agent_where: string;
  agent_id: string;
}

// ===========================================================================
// POST /agent/terminate
// ===========================================================================

export interface TerminateBody {
  agent_id: string;
  from_agent_id: string;
  from_agent_where: string;
}

// ===========================================================================
// POST /agent/terminate_ack
// ===========================================================================

export interface TerminateAckBody {
  from_agent_id: string;
  from_agent_where: string;
  agent_id: string;
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
// Outgoing messages
// ===========================================================================

export interface OutgoingMessage {
  toUrl: string;
  kind: OutgoingKind;
}

export type OutgoingKind =
  | { type: "Reply"; body: AgentReplyBody }
  | { type: "Request"; body: AgentRequestBody }
  | { type: "Return"; body: AgentReturnBody }
  | { type: "Terminate"; body: TerminateBody }
  | { type: "TerminateAck"; body: TerminateAckBody }
  | {
      type: "Spawn";
      body: SpawnAgentRequest;
      parentAgentId: string;
      provisionalChildId: string;
    };
