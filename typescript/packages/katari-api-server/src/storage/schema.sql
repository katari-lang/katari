-- katari-api-server schema.
--
-- Layout (3 module + bus 設計):
--   - projects                  : top-level deploy unit (1 project = 1 app)
--   - snapshots                 : 1 apply で凍結された (IR + sidecar JS + schema)
--   - engine_checkpoints        : CORE module の per-snapshot 状態
--   - agents                    : API → CORE delegation rows (= CLI が起動した agent)
--   - ffi_pending_delegations   : FFI Runner の in-flight delegate
--   - ffi_pending_escalations   : FFI Runner の in-flight escalate
--   - api_pending_escalations   : AI から user への質問キュー

CREATE TABLE IF NOT EXISTS projects (
  id          UUID PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS snapshots (
  id              UUID PRIMARY KEY,
  project_id      UUID NOT NULL REFERENCES projects(id),
  ir_module       JSONB NOT NULL,
  sidecar_bundle  JSONB,
  schema_bundle   JSONB NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS snapshots_project_created_idx
  ON snapshots (project_id, created_at DESC);

CREATE TABLE IF NOT EXISTS engine_checkpoints (
  snapshot_id UUID PRIMARY KEY REFERENCES snapshots(id) ON DELETE CASCADE,
  checkpoint  JSONB NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Agent rows = API module の pendingDelegateOut (CORE 宛) の永続化先。
-- delegationId をそのまま PK に使う。
CREATE TABLE IF NOT EXISTS agents (
  id              UUID PRIMARY KEY,         -- = delegationId
  delegation_id   UUID UNIQUE NOT NULL,
  snapshot_id     UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  qualified_name  TEXT NOT NULL,
  args            JSONB NOT NULL,
  state           TEXT NOT NULL,            -- running / cancelling / cancelled / succeeded / error
  result          JSONB,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agents_snapshot_state_idx
  ON agents (snapshot_id, state);
CREATE INDEX IF NOT EXISTS agents_delegation_idx
  ON agents (delegation_id);

CREATE TABLE IF NOT EXISTS ffi_pending_delegations (
  delegation_id            UUID PRIMARY KEY,
  snapshot_id              UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  peer_endpoint            TEXT NOT NULL,
  agent_def_id             JSONB NOT NULL,
  args                     JSONB NOT NULL,
  state                    TEXT NOT NULL,             -- running / cancelling
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  -- NULL = parent delegation (caller → ext); non-NULL = ext-spawned
  -- child agent that was started via katari.delegate(...). The value
  -- points at the owning ext invocation so escalate relays and restart
  -- cleanup can find the parent.
  parent_ext_delegation_id UUID
);
CREATE INDEX IF NOT EXISTS ffi_pending_delegations_snapshot_idx
  ON ffi_pending_delegations (snapshot_id);
CREATE INDEX IF NOT EXISTS ffi_pending_delegations_parent_idx
  ON ffi_pending_delegations (parent_ext_delegation_id);

CREATE TABLE IF NOT EXISTS ffi_pending_escalations (
  escalation_id  UUID PRIMARY KEY,
  delegation_id  UUID NOT NULL,
  snapshot_id    UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  peer_endpoint  TEXT NOT NULL,
  agent_def_id   JSONB NOT NULL,
  args           JSONB NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ffi_pending_escalations_snapshot_idx
  ON ffi_pending_escalations (snapshot_id);

CREATE TABLE IF NOT EXISTS api_pending_escalations (
  escalation_id  UUID PRIMARY KEY,
  delegation_id  UUID NOT NULL,
  snapshot_id    UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  agent_def_id   JSONB NOT NULL,
  args           JSONB NOT NULL,
  state          TEXT NOT NULL,             -- open / answered / cancelled
  value          JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS api_pending_escalations_snapshot_state_idx
  ON api_pending_escalations (snapshot_id, state);

-- Migration hint for existing deployments (v1 prototype):
--   DROP TABLE IF EXISTS machine_diffs;
--   DROP TABLE IF EXISTS machine_snapshots;        -- replaced by engine_checkpoints
--   DROP TABLE IF EXISTS module_versions;          -- replaced by snapshots + projects
--
-- v0.1.0 schema migration: add ON DELETE CASCADE on snapshot_id FKs that
-- were missing it in earlier prototypes. Safe to re-run.
DO $$
BEGIN
  -- engine_checkpoints.snapshot_id
  IF EXISTS (
    SELECT 1 FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage k
      ON rc.constraint_name = k.constraint_name
    WHERE k.table_name = 'engine_checkpoints'
      AND k.column_name = 'snapshot_id'
      AND rc.delete_rule <> 'CASCADE'
  ) THEN
    EXECUTE 'ALTER TABLE engine_checkpoints
             DROP CONSTRAINT engine_checkpoints_snapshot_id_fkey,
             ADD CONSTRAINT engine_checkpoints_snapshot_id_fkey
               FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE';
  END IF;

  -- agents.snapshot_id
  IF EXISTS (
    SELECT 1 FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage k
      ON rc.constraint_name = k.constraint_name
    WHERE k.table_name = 'agents'
      AND k.column_name = 'snapshot_id'
      AND rc.delete_rule <> 'CASCADE'
  ) THEN
    EXECUTE 'ALTER TABLE agents
             DROP CONSTRAINT agents_snapshot_id_fkey,
             ADD CONSTRAINT agents_snapshot_id_fkey
               FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE';
  END IF;

  -- api_pending_escalations.snapshot_id
  IF EXISTS (
    SELECT 1 FROM information_schema.referential_constraints rc
    JOIN information_schema.key_column_usage k
      ON rc.constraint_name = k.constraint_name
    WHERE k.table_name = 'api_pending_escalations'
      AND k.column_name = 'snapshot_id'
      AND rc.delete_rule <> 'CASCADE'
  ) THEN
    EXECUTE 'ALTER TABLE api_pending_escalations
             DROP CONSTRAINT api_pending_escalations_snapshot_id_fkey,
             ADD CONSTRAINT api_pending_escalations_snapshot_id_fkey
               FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE';
  END IF;
END $$;
