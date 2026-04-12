pub mod types;

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::{Json, Router};
use tokio::sync::Mutex;

pub use types::*;

// ===========================================================================
// Trait
// ===========================================================================

#[derive(Debug)]
pub enum ProtocolError {
    AgentNotFound(String),
    RequestNotFound(String),
    ChildNotFound(String),
    NotImplemented(String),
    Internal(String),
}

/// Trait for backends that participate in the Katari agent protocol.
pub trait KatariProtocol: Send {
    // GET /request
    fn list_requests(&self, module_name: Option<&str>) -> Vec<RequestInfo>;

    // GET /agent_def
    fn list_agent_defs(&self, module_name: Option<&str>) -> Vec<AgentDefInfo>;

    // GET /agent
    fn list_agents(&self) -> Vec<AgentSummary>;

    // GET /agent/:agent_id
    fn get_agent(&self, agent_id: &str) -> Result<AgentDetail, ProtocolError>;

    // POST /agent
    fn spawn_agent(
        &mut self,
        req: &SpawnAgentRequest,
    ) -> Result<(SpawnAgentResponse, Vec<OutgoingMessage>), ProtocolError>;

    // POST /agent/request
    fn deliver_request(
        &mut self,
        req: &AgentRequestBody,
    ) -> Result<Vec<OutgoingMessage>, ProtocolError>;

    // POST /agent/reply
    fn deliver_reply(
        &mut self,
        req: &AgentReplyBody,
    ) -> Result<Vec<OutgoingMessage>, ProtocolError>;

    // POST /agent/terminate
    fn terminate_agent(
        &mut self,
        req: &TerminateBody,
    ) -> Result<Vec<OutgoingMessage>, ProtocolError>;

    // POST /agent/return
    fn deliver_return(
        &mut self,
        req: &AgentReturnBody,
    ) -> Result<Vec<OutgoingMessage>, ProtocolError>;

    // POST /agent/terminate_ack
    fn deliver_terminate_ack(
        &mut self,
        req: &TerminateAckBody,
    ) -> Result<Vec<OutgoingMessage>, ProtocolError>;
}

// ===========================================================================
// State
// ===========================================================================

pub struct KatariState<R> {
    pub protocol: Arc<Mutex<R>>,
    pub http_client: reqwest::Client,
}

impl<R> Clone for KatariState<R> {
    fn clone(&self) -> Self {
        Self {
            protocol: self.protocol.clone(),
            http_client: self.http_client.clone(),
        }
    }
}

// ===========================================================================
// Handlers — GET
// ===========================================================================

async fn handle_list_requests<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Query(query): Query<ListRequestsQuery>,
) -> Json<Vec<RequestInfo>> {
    let rt = state.protocol.lock().await;
    Json(rt.list_requests(query.module_name.as_deref()))
}

async fn handle_list_agent_defs<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Query(query): Query<ListAgentDefsQuery>,
) -> Json<Vec<AgentDefInfo>> {
    let rt = state.protocol.lock().await;
    Json(rt.list_agent_defs(query.module_name.as_deref()))
}

async fn handle_list_agents<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
) -> Json<Vec<AgentSummary>> {
    let rt = state.protocol.lock().await;
    Json(rt.list_agents())
}

async fn handle_get_agent<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Path(agent_id): Path<String>,
) -> Result<Json<AgentDetail>, (StatusCode, Json<ErrorResponse>)> {
    let rt = state.protocol.lock().await;
    rt.get_agent(&agent_id).map(Json).map_err(error_response)
}

// ===========================================================================
// Handlers — POST
// ===========================================================================

async fn handle_spawn_agent<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<SpawnAgentRequest>,
) -> Result<Json<SpawnAgentResponse>, (StatusCode, Json<ErrorResponse>)> {
    let (resp, messages) = {
        let mut rt = state.protocol.lock().await;
        rt.spawn_agent(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(resp))
}

async fn handle_agent_request<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<AgentRequestBody>,
) -> Result<Json<SuccessResponse>, (StatusCode, Json<ErrorResponse>)> {
    let messages = {
        let mut rt = state.protocol.lock().await;
        rt.deliver_request(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(SuccessResponse { success: true }))
}

async fn handle_agent_reply<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<AgentReplyBody>,
) -> Result<Json<SuccessResponse>, (StatusCode, Json<ErrorResponse>)> {
    let messages = {
        let mut rt = state.protocol.lock().await;
        rt.deliver_reply(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(SuccessResponse { success: true }))
}

async fn handle_terminate<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<TerminateBody>,
) -> Result<Json<SuccessResponse>, (StatusCode, Json<ErrorResponse>)> {
    let messages = {
        let mut rt = state.protocol.lock().await;
        rt.terminate_agent(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(SuccessResponse { success: true }))
}

async fn handle_agent_return<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<AgentReturnBody>,
) -> Result<Json<SuccessResponse>, (StatusCode, Json<ErrorResponse>)> {
    let messages = {
        let mut rt = state.protocol.lock().await;
        rt.deliver_return(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(SuccessResponse { success: true }))
}

async fn handle_terminate_ack<R: KatariProtocol + 'static>(
    State(state): State<KatariState<R>>,
    Json(body): Json<TerminateAckBody>,
) -> Result<Json<SuccessResponse>, (StatusCode, Json<ErrorResponse>)> {
    let messages = {
        let mut rt = state.protocol.lock().await;
        rt.deliver_terminate_ack(&body).map_err(error_response)?
    };
    send_outgoing_messages(&state.http_client, messages).await;
    Ok(Json(SuccessResponse { success: true }))
}

// ===========================================================================
// Router
// ===========================================================================

/// Build an axum router for the Katari protocol endpoints.
///
/// Mount this at your katari base URL:
/// ```ignore
/// Router::new()
///     .nest("/katari", katari_protocol::build_katari_router(state))
/// ```
pub fn build_katari_router<R: KatariProtocol + 'static>(state: KatariState<R>) -> Router {
    Router::new()
        .route("/request", axum::routing::get(handle_list_requests::<R>))
        .route(
            "/agent_def",
            axum::routing::get(handle_list_agent_defs::<R>),
        )
        .route(
            "/agent",
            axum::routing::get(handle_list_agents::<R>)
                .post(handle_spawn_agent::<R>),
        )
        .route(
            "/agent/{agent_id}",
            axum::routing::get(handle_get_agent::<R>),
        )
        .route(
            "/agent/request",
            axum::routing::post(handle_agent_request::<R>),
        )
        .route(
            "/agent/reply",
            axum::routing::post(handle_agent_reply::<R>),
        )
        .route(
            "/agent/terminate",
            axum::routing::post(handle_terminate::<R>),
        )
        .route(
            "/agent/return",
            axum::routing::post(handle_agent_return::<R>),
        )
        .route(
            "/agent/terminate_ack",
            axum::routing::post(handle_terminate_ack::<R>),
        )
        .with_state(state)
}

// ===========================================================================
// Outgoing message delivery
// ===========================================================================

/// Send outgoing messages to other servers via HTTP POST.
pub async fn send_outgoing_messages(
    http_client: &reqwest::Client,
    messages: Vec<OutgoingMessage>,
) {
    for msg in messages {
        let (path, body) = match &msg.kind {
            OutgoingKind::Reply(b) => ("/agent/reply", serde_json::to_value(b)),
            OutgoingKind::Request(b) => ("/agent/request", serde_json::to_value(b)),
            OutgoingKind::Return(b) => ("/agent/return", serde_json::to_value(b)),
            OutgoingKind::Terminate(b) => ("/agent/terminate", serde_json::to_value(b)),
            OutgoingKind::TerminateAck(b) => ("/agent/terminate_ack", serde_json::to_value(b)),
        };

        let body = match body {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(error = %e, "failed to serialize outgoing message");
                continue;
            }
        };

        let url = format!("{}{}", msg.to_url, path);
        let client = http_client.clone();
        tokio::spawn(async move {
            match client.post(&url).json(&body).send().await {
                Ok(resp) => {
                    if !resp.status().is_success() {
                        tracing::warn!(
                            url = %url,
                            status = %resp.status(),
                            "outgoing message delivery failed"
                        );
                    }
                }
                Err(e) => {
                    tracing::warn!(url = %url, error = %e, "failed to send outgoing message");
                }
            }
        });
    }
}

// ===========================================================================
// Error helpers
// ===========================================================================

fn error_response(err: ProtocolError) -> (StatusCode, Json<ErrorResponse>) {
    let (status, msg) = match &err {
        ProtocolError::AgentNotFound(id) => {
            (StatusCode::NOT_FOUND, format!("agent '{}' not found", id))
        }
        ProtocolError::RequestNotFound(id) => (
            StatusCode::NOT_FOUND,
            format!("request '{}' not found", id),
        ),
        ProtocolError::ChildNotFound(id) => (
            StatusCode::NOT_FOUND,
            format!("unknown child agent: {}", id),
        ),
        ProtocolError::NotImplemented(msg) => (StatusCode::NOT_IMPLEMENTED, msg.clone()),
        ProtocolError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg.clone()),
    };
    (status, Json(ErrorResponse { error: msg }))
}
