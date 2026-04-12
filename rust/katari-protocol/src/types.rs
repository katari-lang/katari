use serde::{Deserialize, Serialize};

// ===========================================================================
// GET /request
// ===========================================================================

#[derive(Debug, Deserialize)]
pub struct ListRequestsQuery {
    pub module_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct RequestInfo {
    pub request_id: String,
    pub request_where: String,
    pub name: String,
    pub description: String,
    pub arg_types: Vec<serde_json::Value>,
    pub return_type: serde_json::Value,
}

// ===========================================================================
// GET /agent_def
// ===========================================================================

#[derive(Debug, Deserialize)]
pub struct ListAgentDefsQuery {
    pub module_name: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AgentDefInfo {
    pub agent_def_id: String,
    pub agent_def_where: String,
    pub name: String,
    pub description: String,
    pub arg_types: Vec<serde_json::Value>,
    pub return_type: serde_json::Value,
    pub with_effects: Vec<String>,
}

// ===========================================================================
// GET /agent
// ===========================================================================

#[derive(Debug, Serialize)]
pub struct AgentSummary {
    pub agent_id: String,
    pub agent_where: String,
    pub agent_def_id: String,
    pub args: Vec<serde_json::Value>,
}

// ===========================================================================
// GET /agent/:agent_id
// ===========================================================================

#[derive(Debug, Serialize)]
pub struct AgentDetail {
    pub agent_id: String,
    pub agent_where: String,
    pub agent_def_id: String,
    pub args: Vec<serde_json::Value>,
    pub parent_agent_id: String,
    pub parent_agent_where: String,
    pub with_effects: Vec<String>,
    pub child_agents: Vec<ChildAgentRef>,
}

#[derive(Debug, Serialize)]
pub struct ChildAgentRef {
    pub agent_id: String,
    pub agent_where: String,
}

// ===========================================================================
// POST /agent (spawn)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SpawnAgentRequest {
    pub agent_def_id: String,
    pub args: Vec<serde_json::Value>,
    pub parent_agent_id: String,
    pub parent_agent_where: String,
    #[serde(default)]
    pub with_effects: Vec<String>,
    #[serde(default)]
    pub call_stack: Vec<CallStackEntry>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct CallStackEntry {
    pub agent_def_id: String,
    pub agent_def_where: String,
    pub agent_def_name: String,
}

#[derive(Debug, Serialize)]
pub struct SpawnAgentResponse {
    pub agent_id: String,
    pub agent_where: String,
}

// ===========================================================================
// POST /agent/request (child → parent)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentRequestBody {
    pub request_id: String,
    pub request_name: String,
    pub args: Vec<serde_json::Value>,
    pub from_agent_id: String,
    pub from_agent_where: String,
}

// ===========================================================================
// POST /agent/reply (parent → child)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentReplyBody {
    pub request_id: String,
    pub result: serde_json::Value,
    pub from_agent_id: String,
    pub from_agent_where: String,
    pub agent_id: String,
}

// ===========================================================================
// POST /agent/terminate (parent → child)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TerminateBody {
    pub agent_id: String,
    pub from_agent_id: String,
    pub from_agent_where: String,
}

// ===========================================================================
// POST /agent/return (child → parent)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct AgentReturnBody {
    pub result: serde_json::Value,
    pub from_agent_id: String,
    pub from_agent_where: String,
    pub agent_id: String,
}

// ===========================================================================
// POST /agent/terminate_ack (child → parent)
// ===========================================================================

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TerminateAckBody {
    pub from_agent_id: String,
    pub from_agent_where: String,
    pub agent_id: String,
}

// ===========================================================================
// Common responses
// ===========================================================================

#[derive(Debug, Serialize)]
pub struct SuccessResponse {
    pub success: bool,
}

#[derive(Debug, Serialize)]
pub struct ErrorResponse {
    pub error: String,
}

// ===========================================================================
// Outgoing messages (to be sent via HTTP after handling)
// ===========================================================================

/// An outgoing message to be sent to another server.
#[derive(Debug, Clone)]
pub struct OutgoingMessage {
    /// Target server's katari base URL (e.g. "http://localhost:8001/katari")
    pub to_url: String,
    pub kind: OutgoingKind,
}

#[derive(Debug, Clone)]
pub enum OutgoingKind {
    Reply(AgentReplyBody),
    Request(AgentRequestBody),
    Return(AgentReturnBody),
    Terminate(TerminateBody),
    TerminateAck(TerminateAckBody),
}
