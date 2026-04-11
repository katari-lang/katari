use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use base64::Engine;

use crate::bytecode::decode_module;

use super::state::AppState;
use super::types::{AgentDefInfo, ApplyRequest, ApplyResponse, RequestDefInfo};

/// POST /apply
///
/// Decodes a base64-encoded KTRI binary, registers the module with its
/// agent name-to-ID mapping and schemas into the runtime, and persists
/// the module to the database.
pub async fn apply(
    State(state): State<AppState>,
    Json(body): Json<ApplyRequest>,
) -> (StatusCode, Json<ApplyResponse>) {
    // Decode base64
    let bytes = match base64::engine::general_purpose::STANDARD.decode(&body.ir_binary) {
        Ok(b) => b,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApplyResponse {
                    ok: false,
                    error: Some(format!("base64 decode error: {e}")),
                    module_name: None,
                    agents: None,
                    requests: None,
                }),
            );
        }
    };

    // Decode KTRI binary
    let module = match decode_module(&bytes) {
        Ok(m) => m,
        Err(e) => {
            return (
                StatusCode::BAD_REQUEST,
                Json(ApplyResponse {
                    ok: false,
                    error: Some(format!("KTRI decode error: {e}")),
                    module_name: None,
                    agents: None,
                    requests: None,
                }),
            );
        }
    };

    let module_name = module.name.clone();

    let agents: Vec<AgentDefInfo> = module
        .agents
        .iter()
        .map(|a| AgentDefInfo {
            id: a.id,
            name: a.name.clone(),
        })
        .collect();

    let requests: Vec<RequestDefInfo> = module
        .requests
        .iter()
        .map(|r| RequestDefInfo {
            id: r.id,
            name: r.name.clone(),
            from: r.from.clone(),
        })
        .collect();

    // Apply to runtime (hold mutex only for the synchronous part)
    {
        let mut rt = state.runtime.lock().await;
        rt.apply_module(module, body.agents.clone(), body.schemas.clone());
    }

    // Persist to DB asynchronously (mutex already released)
    match state
        .db
        .save_module(&module_name, &bytes, &body.agents, &body.schemas)
        .await
    {
        Ok(version) => {
            tracing::info!(module = %module_name, version = version, "module applied and saved");
        }
        Err(e) => {
            tracing::error!(module = %module_name, error = %e, "module applied but DB save failed");
        }
    }

    (
        StatusCode::OK,
        Json(ApplyResponse {
            ok: true,
            error: None,
            module_name: Some(module_name),
            agents: Some(agents),
            requests: Some(requests),
        }),
    )
}
