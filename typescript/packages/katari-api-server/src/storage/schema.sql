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
--   - env_entries        : per-project env store (shared across a project's snapshots).

-- Pre-v0.1.0 prototype tables that have been absorbed into the unified
-- `delegations` / `escalations` / `runs_audit` design. Dropped here so a
-- dev environment that ran an older schema doesn't keep stale rows.
DROP TABLE IF EXISTS agents CASCADE;
DROP TABLE IF EXISTS api_pending_escalations CASCADE;

CREATE TABLE IF NOT EXISTS projects (
  id          UUID PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  -- One-line summary from `katari.toml`. Long-form README is its own
  -- column so dashboard hero text doesn't pull a multi-KB body across
  -- the wire when we just need the headline.
  description TEXT,
  readme      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS snapshots (
  id              UUID PRIMARY KEY,
  project_id      UUID NOT NULL REFERENCES projects(id),
  ir_module       JSONB NOT NULL,
  sidecar_bundle  JSONB,
  schema_bundle   JSONB NOT NULL,
  message         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS snapshots_project_created_idx
  ON snapshots (project_id, created_at DESC);

-- Per-agent-instance shard: the encrypted engine checkpoint for one warm CORE
-- shard, keyed by (project_id, shard_id). `current_snapshot` records which code
-- version the instance runs (RESTRICT: a snapshot in use by a live shard cannot
-- be deleted). Completed shards are physically DELETEd. Replaces the old
-- per-snapshot `engine_checkpoints` (warm per-project actor model).
CREATE TABLE IF NOT EXISTS engine_shards (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  shard_id          TEXT NOT NULL,
  current_snapshot  UUID NOT NULL REFERENCES snapshots(id),
  payload           JSONB NOT NULL,
  status            TEXT NOT NULL,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, shard_id)
);
CREATE INDEX IF NOT EXISTS engine_shards_project_status_idx
  ON engine_shards (project_id, status);

-- Per-project routing index (delegation / escalation id -> shard). One JSONB
-- row per project; the CoreModule keeps it warm in memory and writes through.
CREATE TABLE IF NOT EXISTS project_index (
  project_id  UUID PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
  payload     JSONB NOT NULL,
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
-- `project_id` (not snapshot_id): a delegation is a katari-protocol entity
-- scoped to a project. Which code version (snapshot) a delegation runs is
-- module-private state (CORE: engine_shards.current_snapshot; FFI: its own
-- tables) and deliberately does NOT live on this protocol table.
CREATE TABLE IF NOT EXISTS delegations (
  id                   UUID PRIMARY KEY,
  root_delegation_id   UUID NOT NULL,
  parent_delegation_id UUID,
  project_id           UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS delegations_project_state_idx
  ON delegations (project_id, state);
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
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
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
CREATE INDEX IF NOT EXISTS escalations_project_state_idx
  ON escalations (project_id, state);
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
  name            TEXT NOT NULL,
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

-- Per-project env store. Each project owns its own key/value space (an env
-- is part of a project's runtime config, not a global), keyed by
-- (project_id, key). Shared across that project's snapshots — env outlives
-- any single deploy. `value` holds plaintext for non-secret entries and
-- AES-GCM ciphertext for secret entries; the EnvModule encrypts/decrypts at
-- its boundary so storage never sees plaintext credentials.
CREATE TABLE IF NOT EXISTS env_entries (
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  is_secret  BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, key)
);

-- ─── Value store: 3-layer byte-sequence storage ─────────────────────────────
--
-- All byte sequences (`string` / `file` / `secret`) are content-addressed.
-- Three layers mirror the run / delegation "persistent record + freeable
-- resource" split (D30):
--   - value_refs        : ephemeral CORE/FFI intermediate values. Owned by a
--                         shard, reclaimed by reachability GC.
--   - api_files         : persistent API-owned records (= user-managed files).
--                         Not traversal-GC'd; deleted only on explicit request.
--   - value_blobs       : project-wide content-addressed refcount LEDGER (the
--                         dedup unit). Both layers reference a blob by hash; a
--                         refcount frees it at zero. The BYTES live in a
--                         pluggable BlobStore (local FS / S3), not Postgres.
-- `ref = a module's handle, blob = the file's bytes.`
--
-- Project-scoped via `project_id` (a value's identity is (module, id); the
-- project is ambient — D24). See docs/2026-05-30-storage-schema-and-api.md §2.

-- (a) ephemeral ref: CORE/FFI intermediate values. GC'd by single-owner
-- ownership (Phase G): every ref is owned by exactly one durable entity
-- (`owner_delegation_id` — a delegation while running, or a run / escalation
-- afterwards). Ownership only moves UP the delegation tree (no orphans, since
-- ancestors outlive descendants), at protocol events: on a delegation's
-- terminal the escaping refs are re-owned by the parent and the rest dropped;
-- on escalate they transfer to the receiver. A blob is freed when its last ref
-- is dropped (value_blobs refcount). `refs_to` is the closure adjacency (the
-- refs a closure blob captures) so the upward move drags captures along. A
-- crash backstop drops refs whose owner no longer exists.
CREATE TABLE IF NOT EXISTS value_refs (
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  owner_module        TEXT NOT NULL,             -- 'core' | 'ffi'
  id                  UUID NOT NULL,
  state               TEXT NOT NULL,             -- v0.1.0: 'complete' | 'errored'
  semantic_kind       TEXT NOT NULL,             -- 'string' | 'file' | 'secret' | 'closure'
  owner_delegation_id UUID,                       -- the owning entity (delegation/run/escalation); null = unowned
  refs_to             JSONB NOT NULL DEFAULT '[]', -- [{module,id}] refs this ref captures (closures); for the upward drag
  hash                TEXT,                       -- -> value_blobs.hash (null while errored)
  size                BIGINT,
  content_type        TEXT,
  error_message       TEXT,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, owner_module, id)
);
CREATE INDEX IF NOT EXISTS value_refs_owner_idx ON value_refs (project_id, owner_delegation_id);
CREATE INDEX IF NOT EXISTS value_refs_hash_idx  ON value_refs (project_id, hash);

-- (b) persistent file: API-owned record (= runs_audit's positioning). Outside
-- reachability GC; survives until the user deletes it. A file value carries
-- ref(module=api, id=<this id>).
CREATE TABLE IF NOT EXISTS api_files (
  project_id    UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  id            UUID NOT NULL,
  hash          TEXT NOT NULL,                 -- -> value_blobs.hash
  size          BIGINT NOT NULL,
  content_type  TEXT,
  display_name  TEXT,                          -- UI label (= original file name)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, id)
);
CREATE INDEX IF NOT EXISTS api_files_hash_idx ON api_files (project_id, hash);

-- (c) shared blob ledger: project-wide content-addressed refcount (the dedup
-- unit). ref_count = (reachable value_refs) + (api_files) referencing this
-- hash; 0 => the bytes are physically deleted from the BlobStore. The BYTES
-- themselves do NOT live in Postgres — they are held by a pluggable BlobStore
-- (local FS / S3, see blob-store.ts), keyed by (project_id, hash). Postgres is
-- a poor home for large binaries (storage/IOPS/backup/WAL), so it keeps only
-- this ledger. Observable `building` is v0.2.
CREATE TABLE IF NOT EXISTS value_blobs (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  hash              TEXT NOT NULL,
  total_size        BIGINT NOT NULL,
  ref_count         INTEGER NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_accessed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, hash)
);
