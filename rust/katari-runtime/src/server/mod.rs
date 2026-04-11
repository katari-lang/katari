pub mod apply;
pub mod protocol;
pub mod run;
pub mod state;
pub mod types;

use axum::Router;
use tower_http::cors::CorsLayer;
use tower_http::trace::TraceLayer;

use self::state::AppState;

/// Build the complete axum router with all Katari runtime endpoints.
pub fn build_router(state: AppState) -> Router {
    let katari_routes = Router::new()
        .route("/reply", axum::routing::post(protocol::reply))
        .route("/request", axum::routing::post(protocol::external_request));

    Router::new()
        .route("/apply", axum::routing::post(apply::apply))
        .route("/run", axum::routing::post(run::run_agent))
        .route("/run", axum::routing::get(run::list_agents))
        .route("/run/{agent_id}", axum::routing::get(run::get_agent_status))
        .nest("/katari", katari_routes)
        .layer(TraceLayer::new_for_http())
        .layer(CorsLayer::permissive())
        .with_state(state)
}
