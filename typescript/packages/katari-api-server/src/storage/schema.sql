-- katari-api-server schema (v0.1.0).
--
-- Tables:
--   - projects           : top-level deploy unit (1 project = 1 app)
--   - snapshots          : a single apply's frozen (IR + sidecar JS + schema + message)
--   - engine_checkpoints : per-snapshot CORE state
--   - delegations        : live execution entities, owned by the Module that ISSUED
--                          the delegate event. One physical table; each Module's
--                          repo filters by `caller_endpoint = self`. Rows are
--                          deleted on terminal state (delegateAck / terminateAck).
--   - escalations        : live escalation entities, same ownership pattern.
--                          State terminal on answered / cancelled (= cascade from
--                          parent delegation cancel).
--   - runs_audit         : ApiModule-specific persistent log of operator-launched
--                          root delegations. Stays even after the live row in
--                          `delegations` is deleted, so the "Runs" page can show
--                          terminal states + results + cancel reason.
--   - env_entries        : runtime-wide env store (shared across snapshots).

-- Pre-v0.1.0 prototype tables that have been absorbed into the unified
-- `delegations` / `escalations` / `runs_audit` design. Dropped here so a
-- dev environment that ran an older schema doesn't keep stale rows.
DROP TABLE IF EXISTS agents CASCADE;
DROP TABLE IF EXISTS api_pending_escalations CASCADE;

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
  message         TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS snapshots_project_created_idx
  ON snapshots (project_id, created_at DESC);

CREATE TABLE IF NOT EXISTS engine_checkpoints (
  snapshot_id UUID PRIMARY KEY REFERENCES snapshots(id) ON DELETE CASCADE,
  checkpoint  JSONB NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Live delegation entities. One row per in-flight call frame, regardless
-- of which Module issued it. The Module that issued the delegate event
-- (= `caller_endpoint`) owns writes for this row. Terminal state =
-- physical DELETE; persistent audit lives in `runs_audit` for roots only.
--
-- `root_delegation_id` is denormalised so the tree query for an entire
-- run is one indexed lookup (`WHERE root_delegation_id = ?`) rather than
-- a recursive CTE walking parent links.
CREATE TABLE IF NOT EXISTS delegations (
  id                   UUID PRIMARY KEY,
  root_delegation_id   UUID NOT NULL,
  parent_delegation_id UUID,
  snapshot_id          UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  caller_endpoint      TEXT NOT NULL,
  owner_endpoint       TEXT NOT NULL,
  agent_def_id         JSONB NOT NULL,
  args                 JSONB NOT NULL,
  state                TEXT NOT NULL,             -- 'running' | 'cancelling'
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS delegations_root_idx
  ON delegations (root_delegation_id);
CREATE INDEX IF NOT EXISTS delegations_parent_idx
  ON delegations (parent_delegation_id);
CREATE INDEX IF NOT EXISTS delegations_snapshot_state_idx
  ON delegations (snapshot_id, state);
CREATE INDEX IF NOT EXISTS delegations_caller_root_idx
  ON delegations (caller_endpoint, root_delegation_id);

-- Live escalation entities. Each row is one in-flight `escalate` event
-- raised inside a delegation, awaiting an `escalateAck`. `state =
-- cancelled` is reached only via cascade when the parent delegation
-- chain is cancelled (= no standalone cancel endpoint).
CREATE TABLE IF NOT EXISTS escalations (
  id                  UUID PRIMARY KEY,
  delegation_id       UUID NOT NULL,
  root_delegation_id  UUID NOT NULL,
  snapshot_id         UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  caller_endpoint     TEXT NOT NULL,
  receiver_endpoint   TEXT NOT NULL,
  agent_def_id        JSONB NOT NULL,
  args                JSONB NOT NULL,
  state               TEXT NOT NULL,              -- 'open' | 'answered' | 'cancelled'
  value               JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS escalations_delegation_idx
  ON escalations (delegation_id);
CREATE INDEX IF NOT EXISTS escalations_root_idx
  ON escalations (root_delegation_id);
CREATE INDEX IF NOT EXISTS escalations_snapshot_state_idx
  ON escalations (snapshot_id, state);
CREATE INDEX IF NOT EXISTS escalations_receiver_state_idx
  ON escalations (receiver_endpoint, state);

-- ApiModule's persistent audit log for operator-launched root delegations.
-- A "run" in admin/CLI UX terms is a row here. Lives independently of the
-- live `delegations` row (which is deleted on terminal state), so the
-- operator can review terminal status + result + cancel reason after the
-- bus event has cleared the live entity.
--
-- `cancel_reason` is set when transitioning to `cancelling` and persists
-- through to the terminal state, letting the terminateAck handler decide
-- between `cancelled` (= user pressed cancel) and `error` (= child threw).
CREATE TABLE IF NOT EXISTS runs_audit (
  id              UUID PRIMARY KEY,           -- = root delegation id
  snapshot_id     UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  name            TEXT,
  qualified_name  TEXT NOT NULL,
  args            JSONB NOT NULL,
  state           TEXT NOT NULL,              -- 'running' | 'cancelling' | 'cancelled' | 'error' | 'succeeded'
  cancel_reason   TEXT,                       -- 'user' | 'error' | NULL
  result          JSONB,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS runs_audit_snapshot_idx
  ON runs_audit (snapshot_id);
CREATE INDEX IF NOT EXISTS runs_audit_state_idx
  ON runs_audit (state);
CREATE INDEX IF NOT EXISTS runs_audit_snapshot_state_created_idx
  ON runs_audit (snapshot_id, state, created_at DESC);

-- FFI Module's private sidecar relay state. Phase 5 of the v0.1.0
-- refactor will merge these into `delegations` / `escalations`; until
-- that lands, the FFI side keeps its own tables for sidecar relay
-- bookkeeping (= ext-call inbound / ext-spawned children / escalation
-- relay map). Tree assembly therefore reads BOTH the unified tables and
-- these for a complete view.
CREATE TABLE IF NOT EXISTS ffi_pending_delegations (
  delegation_id            UUID PRIMARY KEY,
  snapshot_id              UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  peer_endpoint            TEXT NOT NULL,
  agent_def_id             JSONB NOT NULL,
  args                     JSONB NOT NULL,
  state                    TEXT NOT NULL,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
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

-- Runtime-wide env store. Shared across snapshots. `value` holds plaintext
-- for non-secret entries and AES-GCM ciphertext for secret entries; the
-- EnvModule encrypts/decrypts at its boundary so storage never sees
-- plaintext credentials.
CREATE TABLE IF NOT EXISTS env_entries (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  is_secret  BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
