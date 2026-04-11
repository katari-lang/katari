use std::collections::HashMap;

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::{Row, SqlitePool};

/// Database handle for persisting Katari modules.
#[derive(Clone)]
pub struct Db {
    pool: SqlitePool,
}

/// A row from the `modules` table.
pub struct ModuleRow {
    pub version: i64,
    pub name: String,
    pub ktri_binary: Vec<u8>,
    pub agent_name_map: HashMap<String, u32>,
    pub schemas: HashMap<String, serde_json::Value>,
}

impl Db {
    /// Connect to the SQLite database at `url` and run migrations.
    pub async fn connect(url: &str) -> anyhow::Result<Self> {
        let opts: SqliteConnectOptions = url.parse::<SqliteConnectOptions>()?.create_if_missing(true);

        let pool = SqlitePoolOptions::new()
            .max_connections(2)
            .connect_with(opts)
            .await?;

        sqlx::query(
            "CREATE TABLE IF NOT EXISTS modules (
                version INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                ktri_binary BLOB NOT NULL,
                agent_name_map TEXT NOT NULL,
                schemas TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (datetime('now'))
            )",
        )
        .execute(&pool)
        .await?;

        Ok(Self { pool })
    }

    /// Save a module and return its version number.
    pub async fn save_module(
        &self,
        name: &str,
        ktri_binary: &[u8],
        agent_name_map: &HashMap<String, u32>,
        schemas: &HashMap<String, serde_json::Value>,
    ) -> anyhow::Result<i64> {
        let name_map_json = serde_json::to_string(agent_name_map)?;
        let schemas_json = serde_json::to_string(schemas)?;

        let row = sqlx::query(
            "INSERT INTO modules (name, ktri_binary, agent_name_map, schemas) VALUES (?, ?, ?, ?) RETURNING version",
        )
        .bind(name)
        .bind(ktri_binary)
        .bind(&name_map_json)
        .bind(&schemas_json)
        .fetch_one(&self.pool)
        .await?;

        Ok(row.get("version"))
    }

    /// Load the latest module, if any.
    pub async fn load_latest_module(&self) -> anyhow::Result<Option<ModuleRow>> {
        let row = sqlx::query(
            "SELECT version, name, ktri_binary, agent_name_map, schemas FROM modules ORDER BY version DESC LIMIT 1",
        )
        .fetch_optional(&self.pool)
        .await?;

        match row {
            None => Ok(None),
            Some(row) => {
                let name_map_str: String = row.get("agent_name_map");
                let schemas_str: String = row.get("schemas");

                Ok(Some(ModuleRow {
                    version: row.get("version"),
                    name: row.get("name"),
                    ktri_binary: row.get("ktri_binary"),
                    agent_name_map: serde_json::from_str(&name_map_str)?,
                    schemas: serde_json::from_str(&schemas_str)?,
                }))
            }
        }
    }
}
