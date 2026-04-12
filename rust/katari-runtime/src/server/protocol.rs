use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;

use crate::runtime::event::{self, Event, EventKind};
use crate::runtime::thread::PendingRequest;
use crate::runtime::OutgoingReply;

use super::state::AppState;
use super::types::{
    ExternalRequestBody, ExternalRequestResponse, ReplyRequest, ReplyResponse,
};

/// POST /katari/reply
///
/// Delivers a reply value for a pending request in an agent.
pub async fn reply(
    State(state): State<AppState>,
    Json(body): Json<ReplyRequest>,
) -> (StatusCode, Json<ReplyResponse>) {
    let pending_replies = {
        let mut rt = state.runtime.lock().await;

        let agent = match rt.agents.get(&body.agent_id) {
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

        // Find the thread waiting for this request_id
        let thread_id = match event::find_request_thread(agent, &body.request_id) {
            Some(tid) => tid,
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(ReplyResponse {
                        ok: false,
                        error: Some(format!(
                            "no thread waiting for request '{}'",
                            body.request_id
                        )),
                    }),
                );
            }
        };

        // Push Reply event
        rt.push_event(Event {
            agent_id: body.agent_id.clone(),
            thread_id,
            kind: EventKind::Reply {
                request_id: body.request_id.clone(),
                value: body.value,
            },
        });

        rt.run_event_loop();

        tracing::info!(
            agent_id = %body.agent_id,
            request_id = %body.request_id,
            "reply delivered"
        );

        // Drain outgoing replies (mutex still held)
        std::mem::take(&mut rt.outgoing_replies)
    };

    // Send outgoing replies outside of mutex
    send_outgoing_replies(&state, pending_replies).await;

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
    let pending_replies = {
        let mut rt = state.runtime.lock().await;

        let pending = PendingRequest {
            request_id: body.request_id.clone(),
            req_def_id: body.req_def_id,
            args: body.args,
            from_agent_id: body.from_agent_id,
            from_agent_where: body.from_agent_where,
        };

        let agent = match rt.agents.get(&body.agent_id) {
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

        // Find the spawning thread for the child agent that forwarded this request
        let source_thread_id = match agent.children.get(&pending.from_agent_id) {
            Some(&tid) => tid,
            None => {
                return (
                    StatusCode::NOT_FOUND,
                    Json(ExternalRequestResponse {
                        ok: false,
                        error: Some(format!(
                            "unknown child agent: {}",
                            pending.from_agent_id
                        )),
                    }),
                );
            }
        };

        let module = std::sync::Arc::clone(&agent.module);

        // Route request to find the matching handle scope
        match event::route_request_to_handle(
            agent,
            &module,
            source_thread_id,
            pending.req_def_id,
        ) {
            Some((handle_owner_tid, handler_def_tid)) => {
                rt.push_event(Event {
                    agent_id: body.agent_id.clone(),
                    thread_id: handle_owner_tid,
                    kind: EventKind::IncomingRequest {
                        request: pending,
                        handler_def_tid,
                    },
                });
            }
            None => {
                tracing::warn!(
                    agent_id = %body.agent_id,
                    "no handle scope found for external request, forwarding to parent (not yet implemented)"
                );
            }
        }

        rt.run_event_loop();

        tracing::info!(
            agent_id = %body.agent_id,
            request_id = %body.request_id,
            "external request delivered"
        );

        std::mem::take(&mut rt.outgoing_replies)
    };

    send_outgoing_replies(&state, pending_replies).await;

    (
        StatusCode::OK,
        Json(ExternalRequestResponse {
            ok: true,
            error: None,
        }),
    )
}

/// Send outgoing replies to external agents via HTTP POST.
/// Public alias for use from other server modules.
pub async fn send_outgoing_replies_ext(state: &AppState, replies: Vec<OutgoingReply>) {
    send_outgoing_replies(state, replies).await;
}

async fn send_outgoing_replies(state: &AppState, replies: Vec<OutgoingReply>) {
    for reply in replies {
        if reply.to_agent_where.is_empty() {
            tracing::warn!(
                to_agent_id = %reply.to_agent_id,
                request_id = %reply.request_id,
                "cannot send reply: no agent_where URL"
            );
            continue;
        }

        let url = format!("{}/katari/reply", reply.to_agent_where);
        let body = serde_json::json!({
            "agent_id": reply.to_agent_id,
            "request_id": reply.request_id,
            "value": reply.value,
        });

        let client = state.http_client.clone();
        // Fire and forget — spawn so we don't block
        tokio::spawn(async move {
            match client.post(&url).json(&body).send().await {
                Ok(resp) => {
                    if !resp.status().is_success() {
                        tracing::warn!(
                            url = %url,
                            status = %resp.status(),
                            "reply delivery got non-success status"
                        );
                    }
                }
                Err(e) => {
                    tracing::warn!(url = %url, error = %e, "failed to deliver reply");
                }
            }
        });
    }
}
