use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;

use crate::runtime::request;
use crate::runtime::thread::PendingRequest;

use super::state::AppState;
use super::types::{
    ExternalRequestBody, ExternalRequestResponse, ReplyRequest, ReplyResponse,
};

/// POST /katari/reply
///
/// Delivers a reply value for a pending request in an agent. After delivering
/// the reply, the agent is re-executed so it can make progress.
pub async fn reply(
    State(state): State<AppState>,
    Json(body): Json<ReplyRequest>,
) -> (StatusCode, Json<ReplyResponse>) {
    let mut rt = state.runtime.lock().await;

    let agent = match rt.agents.get_mut(&body.agent_id) {
        Some(a) => a,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ReplyResponse {
                    ok: false,
                    error: Some(format!("agent '{}' not found", body.agent_id)),
                }),
            );
        }
    };

    request::on_reply(agent, &body.request_id, body.value);

    // Run the global event loop so all agents can make progress
    let _ = agent; // release mutable borrow on agents map entry
    rt.run_event_loop();

    tracing::info!(
        agent_id = %body.agent_id,
        request_id = %body.request_id,
        "reply delivered"
    );

    (
        StatusCode::OK,
        Json(ReplyResponse {
            ok: true,
            error: None,
        }),
    )
}

/// POST /katari/request
///
/// Receives an external request from a child agent and routes it
/// through the parent agent's handle scopes.
pub async fn external_request(
    State(state): State<AppState>,
    Json(body): Json<ExternalRequestBody>,
) -> (StatusCode, Json<ExternalRequestResponse>) {
    let mut rt = state.runtime.lock().await;

    let pending = PendingRequest {
        request_id: body.request_id.clone(),
        req_def_id: body.req_def_id,
        args: body.args,
        from_agent_id: body.from_agent_id,
        from_agent_where: body.from_agent_where,
    };

    let agent = match rt.agents.get_mut(&body.agent_id) {
        Some(a) => a,
        None => {
            return (
                StatusCode::NOT_FOUND,
                Json(ExternalRequestResponse {
                    ok: false,
                    error: Some(format!("agent '{}' not found", body.agent_id)),
                }),
            );
        }
    };

    let module = std::sync::Arc::clone(&agent.module);
    request::on_external_request(agent, &module, pending);

    // Run the global event loop so all agents can make progress
    let _ = agent;
    rt.run_event_loop();

    tracing::info!(
        agent_id = %body.agent_id,
        request_id = %body.request_id,
        "external request delivered"
    );

    (
        StatusCode::OK,
        Json(ExternalRequestResponse {
            ok: true,
            error: None,
        }),
    )
}
