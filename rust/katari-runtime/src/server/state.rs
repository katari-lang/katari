use std::sync::Arc;

use tokio::sync::Mutex;

use crate::db::Db;
use crate::runtime::Runtime;

/// Shared application state wrapping the Katari runtime.
#[derive(Clone)]
pub struct AppState {
    pub runtime: Arc<Mutex<Runtime>>,
    pub db: Arc<Db>,
}

impl AppState {
    pub fn new(runtime: Runtime, db: Db) -> Self {
        Self {
            runtime: Arc::new(Mutex::new(runtime)),
            db: Arc::new(db),
        }
    }
}
