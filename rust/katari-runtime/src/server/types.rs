use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::value::Value;

// ---------------------------------------------------------------------------
// POST /apply
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ApplyRequest {
    /// Base64-encoded KTRI binary.
    pub ir_binary: String,
    /// Mapping from agent name to agent definition ID.
    pub agents: HashMap<String, u32>,
    /// JSON schemas keyed by name.
    #[serde(default)]
    pub schemas: HashMap<String, serde_json::Value>,
}

#[derive(Debug, Serialize)]
pub struct ApplyResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agents: Option<Vec<AgentDefInfo>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub requests: Option<Vec<RequestDefInfo>>,
}

#[derive(Debug, Serialize)]
pub struct AgentDefInfo {
    pub id: u32,
    pub name: String,
}

#[derive(Debug, Serialize)]
pub struct RequestDefInfo {
    pub id: u32,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
}

// ---------------------------------------------------------------------------
// POST /run
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct RunRequest {
    pub agent_name: String,
    #[serde(default)]
    pub args: Vec<Value>,
}

#[derive(Debug, Serialize)]
pub struct RunResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

// ---------------------------------------------------------------------------
// GET /run/:agent_id
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct AgentStatusResponse {
    pub agent_id: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

// ---------------------------------------------------------------------------
// GET /run
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize)]
pub struct ListResponse {
    pub agent_defs: Vec<AgentDefInfo>,
    pub requests: Vec<RequestDefInfo>,
    pub running_agents: Vec<RunningAgentInfo>,
}

#[derive(Debug, Serialize)]
pub struct RunningAgentInfo {
    pub agent_id: String,
    pub agent_def_id: u32,
    pub status: String,
}

// ---------------------------------------------------------------------------
// Katari Protocol types
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct ReplyRequest {
    pub agent_id: String,
    pub request_id: String,
    pub value: Value,
}

#[derive(Debug, Serialize)]
pub struct ReplyResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ExternalRequestBody {
    pub agent_id: String,
    pub request_id: String,
    pub req_def_id: u32,
    pub args: Vec<Value>,
    pub from_agent_id: String,
    pub from_agent_where: String,
}

#[derive(Debug, Serialize)]
pub struct ExternalRequestResponse {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub ok: bool,
    pub error: String,
}
