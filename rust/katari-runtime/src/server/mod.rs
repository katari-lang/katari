pub mod apply;
pub mod run;
pub mod state;
pub mod types;

use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use self::state::AppState;

/// Build the complete axum router with all Katari runtime endpoints.
pub fn build_router(state: AppState) -> Router {
    let katari_state = katari_protocol::KatariState {
        protocol: state.runtime.clone(),
        http_client: state.http_client.clone(),
    };

    // Build outer routes with AppState, then resolve state
    let app = Router::new()
        .route("/apply", axum::routing::post(apply::apply))
        .route("/run", axum::routing::post(run::run_agent))
        .route("/run", axum::routing::get(run::list_agents))
        .route("/run/{agent_id}", axum::routing::get(run::get_agent_status))
        .with_state(state);

    // Nest the katari protocol router (both are Router<()> now)
    app.nest("/katari", katari_protocol::build_katari_router(katari_state))
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
}
