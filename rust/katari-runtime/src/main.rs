use katari_runtime::bytecode::decode_module;
use katari_runtime::db::Db;
use katari_runtime::runtime::Runtime;
use katari_runtime::server;

#[tokio::main]
async fn main() {
    // Initialize tracing
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8000);

    let base_url =
        std::env::var("BASE_URL").unwrap_or_else(|_| format!("http://localhost:{port}"));

    let database_url =
        std::env::var("DATABASE_URL").unwrap_or_else(|_| "sqlite:katari.db".to_string());

    tracing::info!(port = port, base_url = %base_url, database_url = %database_url, "starting Katari runtime server");

    // Connect to DB
    let db = Db::connect(&database_url)
        .await
        .expect("failed to connect to database");

    // Initialize runtime
    let mut runtime = Runtime::new(base_url);

    // Restore latest module from DB if available
    match db.load_latest_module().await {
        Ok(Some(row)) => match decode_module(&row.ktri_binary) {
            Ok(module) => {
                let name = module.name.clone();
                runtime.apply_module(module, row.agent_name_map, row.schemas);
                tracing::info!(
                    module = %name,
                    version = row.version,
                    "restored module from database"
                );
            }
            Err(e) => {
                tracing::error!(error = %e, "failed to decode stored module, starting fresh");
            }
        },
        Ok(None) => {
            tracing::info!("no stored module found, starting fresh");
        }
        Err(e) => {
            tracing::error!(error = %e, "failed to load module from database, starting fresh");
        }
    }

    let state = server::state::AppState::new(runtime, db);
    let app = server::build_router(state);

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .expect("failed to bind TCP listener");

    tracing::info!("listening on 0.0.0.0:{port}");

    axum::serve(listener, app).await.expect("server error");
}
