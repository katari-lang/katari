use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;

use super::state::AppState;
use super::types::{
    AgentDefInfo, AgentStatusResponse, ListResponse, RequestDefInfo, RunRequest, RunResponse,
    RunningAgentInfo,
};

/// POST /run
///
/// Creates a new agent instance by name, executes it, and returns
/// its agent_id and current status.
pub async fn run_agent(
    State(state): State<AppState>,
    Json(body): Json<RunRequest>,
) -> (StatusCode, Json<RunResponse>) {
    let (response, pending_messages) = {
        let mut rt = state.runtime.lock().await;

        let response = match rt.run_agent(&body.agent_name, body.args) {
            Ok(agent_id) => {
                let (status, result, error) = match rt.get_agent_status(&agent_id) {
                    Some(("completed", val)) => ("completed".to_string(), val, None),
                    Some(("error", _)) => (
                        "error".to_string(),
                        None,
                        Some("agent completed with error signal".to_string()),
                    ),
                    Some((s, _)) => (s.to_string(), None, None),
                    None => ("running".to_string(), None, None),
                };

                tracing::info!(
                    agent_id = %agent_id,
                    agent_name = %body.agent_name,
                    status = %status,
                    "agent spawned"
                );

                (
                    StatusCode::OK,
                    Json(RunResponse {
                        ok: true,
                        agent_id: Some(agent_id),
                        status,
                        result,
                        error,
                    }),
                )
            }
            Err(e) => {
                tracing::warn!(agent_name = %body.agent_name, error = %e, "failed to run agent");
                (
                    StatusCode::BAD_REQUEST,
                    Json(RunResponse {
                        ok: false,
                        agent_id: None,
                        status: "error".to_string(),
                        result: None,
                        error: Some(e),
                    }),
                )
            }
        };

        let messages = std::mem::take(&mut rt.outgoing_messages);
        (response, messages)
    };

    // Send outgoing messages outside of mutex
    katari_protocol::send_outgoing_messages(&state.http_client, pending_messages).await;

    response
}

/// GET /run/:agent_id
///
/// Returns the current status of an agent.
pub async fn get_agent_status(
    State(state): State<AppState>,
    Path(agent_id): Path<String>,
) -> (StatusCode, Json<AgentStatusResponse>) {
    let rt = state.runtime.lock().await;

    match rt.get_agent_status(&agent_id) {
        Some(("completed", val)) => (
            StatusCode::OK,
            Json(AgentStatusResponse {
                agent_id,
                status: "completed".to_string(),
                result: val,
                error: None,
            }),
        ),
        Some(("error", _)) => (
            StatusCode::OK,
            Json(AgentStatusResponse {
                agent_id,
                status: "error".to_string(),
                result: None,
                error: Some("agent completed with error signal".to_string()),
            }),
        ),
        Some((status, _)) => (
            StatusCode::OK,
            Json(AgentStatusResponse {
                agent_id,
                status: status.to_string(),
                result: None,
                error: None,
            }),
        ),
        None => (
            StatusCode::NOT_FOUND,
            Json(AgentStatusResponse {
                agent_id,
                status: "not_found".to_string(),
                result: None,
                error: Some("agent not found".to_string()),
            }),
        ),
    }
}

/// GET /run
///
/// Lists all registered agent definitions, request definitions,
/// and currently running agents.
pub async fn list_agents(State(state): State<AppState>) -> Json<ListResponse> {
    let rt = state.runtime.lock().await;

    let agent_defs = rt
        .module
        .as_ref()
        .map(|m| {
            m.agents
                .iter()
                .map(|a| AgentDefInfo {
                    id: a.id,
                    name: a.name.clone(),
                })
                .collect()
        })
        .unwrap_or_default();

    let requests = rt
        .module
        .as_ref()
        .map(|m| {
            m.requests
                .iter()
                .map(|r| RequestDefInfo {
                    id: r.id,
                    name: r.name.clone(),
                    from: r.from.clone(),
                })
                .collect()
        })
        .unwrap_or_default();

    let running_agents = rt
        .agents
        .iter()
        .map(|(id, agent)| {
            let status = rt
                .get_agent_status(id)
                .map(|(s, _)| s.to_string())
                .unwrap_or_else(|| "unknown".to_string());
            RunningAgentInfo {
                agent_id: id.clone(),
                agent_def_id: agent.agent_def_id,
                status,
            }
        })
        .collect();

    Json(ListResponse {
        agent_defs,
        requests,
        running_agents,
    })
}
