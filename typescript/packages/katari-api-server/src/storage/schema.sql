-- katari-api-server schema (v0.1.0 — Entity model).
--
-- See docs/2026-06-01-entity-model.md (the SSoT). The execution layer is two
-- records with distinct owners + nested lifetimes:
--
--   - delegations : the ISSUER-managed request edge. Created by the parent when
--                   it emits a `delegate` (one row per in-flight call request),
--                   deleted by the parent when it receives the result ack. Holds
--                   the parent link (`parent_entity_id` = the issuer's OWN `E`)
--                   on the issuer side; the receiver never reads it (boundary).
--   - entities    : the RECEIVER-managed execution node (the ownership/cascade
--                   root). Created by the child when it begins processing (mints
--                   a fresh `id = E`) from the bus event + ambient context ALONE
--                   (no cross-server read), deleted by the child itself on
--                   terminal. `delegation_id = D` is the back-link the server
--                   uses to route bus `D → E`. lifetime(delegation) ⊇
--                   lifetime(entity); ref ascent is value-driven (see `refs`).
--
-- Everything hangs off entities by `owner_entity_id` / `entity_id` with FK
-- `ON DELETE CASCADE` (the integrity backstop; normal teardown is the protocol's
-- bottom-up self-delete). refs unify the old value_refs + api_files; escalations
-- belong to their RAISER; the API's per-run bookkeeping is the `runs` record.
--
--   - refs        : a blob handle owned by an entity (string / file / secret /
--                   closure). Unifies ephemeral CORE/FFI values AND user files.
--   - escalations : a live capability request, owned by the entity that RAISED
--                   it (state `open` only; terminal = the row is deleted).
--   - runs        : the API module's per-run management record (running /
--                   cancelling / done / error), 1:1 with a run-root entity.
--   - run_escalations_audit : answered user-facing escalations kept under a run.
--   - value_blobs : project-wide content-addressed refcount LEDGER (the dedup
--                   unit). Bytes live in a pluggable BlobStore; an AFTER DELETE
--                   trigger on `refs` keeps the refcount correct under both
--                   explicit deletes and entity cascade.
--   - env_entries : per-project env store (shared across a project's snapshots).

-- Pre-Entity-model tables, dropped so a dev DB that ran an older schema doesn't
-- keep stale rows. (Pre-release: the DB is wipeable, no migration path.)
DROP TABLE IF EXISTS agents CASCADE;
DROP TABLE IF EXISTS api_pending_escalations CASCADE;
DROP TABLE IF EXISTS runs_audit CASCADE;
DROP TABLE IF EXISTS value_refs CASCADE;
DROP TABLE IF EXISTS api_files CASCADE;

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
-- shard, keyed by (project_id, shard_id). `shard_id = E` (the CORE entity id).
-- `current_snapshot` records which code version the instance runs (RESTRICT: a
-- snapshot in use by a live shard cannot be deleted). Completed shards are
-- physically DELETEd (no replay → no retention).
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

-- Per-project routing index (delegation / escalation id -> shard E). One JSONB
-- row per project; the CoreModule keeps it warm in memory and writes through.
CREATE TABLE IF NOT EXISTS project_index (
  project_id  UUID PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
  payload     JSONB NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ─── Execution layer: entities (receiver) + delegations (issuer) ─────────────

-- Entity = the execution node (ownership/cascade root). RECEIVER-managed:
-- created when a module begins processing an inbound `delegate` (minting a fresh
-- `id = E`), deleted by that same entity on its terminal (after ref ascent).
--
-- CROSS-SERVER BOUNDARY: an entity stores ONLY what the receiver can know from
-- the bus event + its ambient context — never anything that would require
-- querying the issuer's (another server's) tables. So there is NO
-- `parent_entity_id` / `root_entity_id` here: the parent's `E` is off-bus, and
-- the receiver must not read the issuer's `delegations` row to learn it. The
-- parent link lives on the issuer-side `delegations` row instead (where the
-- issuer writes its OWN `E` locally). Ownership ascent rides the delegation `D`
-- (see `refs`), so the child never needs the parent's `E`.
--
--   - `delegation_id` : the summoning `D` (from the bus; the back-link for `D →
--                       E` routing). NULL only for the project-root entity.
--   - `module`        : 'core' | 'ffi' | 'api' | 'env' — who runs it (self).
--   - `state`         : 'running' | 'cancelling' (the only entity states;
--                       'done'/'error' are the Run record's, not here).
CREATE TABLE IF NOT EXISTS entities (
  id            UUID PRIMARY KEY,
  delegation_id UUID,
  project_id    UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  module        TEXT NOT NULL,                     -- 'core' | 'ffi' | 'api' | 'env'
  state         TEXT NOT NULL,                     -- 'running' | 'cancelling'
  agent_def_id  JSONB,                             -- null for the project root
  args          JSONB NOT NULL DEFAULT '{}',
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS entities_delegation_idx
  ON entities (project_id, delegation_id) WHERE delegation_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS entities_project_state_idx
  ON entities (project_id, state);

-- Delegation = the request edge. ISSUER-managed: the parent INSERTs a row when
-- it emits `delegate(D)` and DELETEs it when it receives the result ack
-- (delegateAck / terminateAck). The receiver NEVER reads, writes, or deletes it
-- (that would cross the server boundary). So lifetime(delegation) ⊇
-- lifetime(entity): the request is born first, dies last. (It is NOT an owner of
-- refs — ref ascent is value-driven; see `refs`.)
--
-- `parent_entity_id` = the issuer's OWN entity, which the issuer knows locally
-- (the run-root for D_core; the emitting CORE shard for a sub-delegate; the
-- project-root for the run-root's D_run). This is the parent link (the entity
-- tree is reconstructed by joining `entities.delegation_id` ↔ `delegations.id`).
-- `target_module` = the `to` endpoint. No `root_entity_id`: a denormalised root
-- would require knowing an ancestor `E` (cross-server) — "all entities under a
-- run" is a local recursive walk on `parent_entity_id`, done aggregator-side.
CREATE TABLE IF NOT EXISTS delegations (
  id                UUID PRIMARY KEY,              -- D
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  parent_entity_id  UUID NOT NULL,                 -- the issuer's own entity (E)
  target_module     TEXT NOT NULL,                 -- 'core' | 'ffi' | 'api' | 'env'
  agent_def_id      JSONB NOT NULL,
  args              JSONB NOT NULL,
  state             TEXT NOT NULL,                 -- 'running' | 'cancelling'
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS delegations_parent_idx ON delegations (parent_entity_id);
CREATE INDEX IF NOT EXISTS delegations_project_state_idx
  ON delegations (project_id, state);

-- Escalation = a live capability request, owned by the entity that RAISED it
-- (the raiser is the subject + holds the delete authority; an ancestor only
-- answers). `state` is 'open' only — answered/cancelled are both terminal = the
-- row is deleted (the raiser self-deletes on escalateAck; cancel cascades when
-- the raiser entity is terminated). No `handler` field (routing-decided,
-- transient). `agent_def_id` = the requested capability / `request`. The history
-- of answered user-facing ones lives under the run (run_escalations_audit).
CREATE TABLE IF NOT EXISTS escalations (
  id              UUID PRIMARY KEY,                -- escalationId
  entity_id       UUID NOT NULL REFERENCES entities(id) ON DELETE CASCADE,  -- raiser
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  agent_def_id    JSONB NOT NULL,
  args            JSONB NOT NULL,
  state           TEXT NOT NULL DEFAULT 'open',    -- 'open' only
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS escalations_entity_idx ON escalations (entity_id);
CREATE INDEX IF NOT EXISTS escalations_project_idx ON escalations (project_id);

-- Run = the API module's per-run management record (NOT an entity state). 1:1
-- with a run-root entity (`id = E_run`). Its state reflects the run's CHILD
-- CORE-root delegation: 'done' on that child's delegateAck, 'error' on a throw,
-- 'cancelling' while a cancel cascades. `core_delegation_id` = the D the run-root
-- issued to summon the CORE root (so a delegateAck/terminateAck routes back to
-- this run, and cancel/recovery can re-issue terminate). Kept as run history.
CREATE TABLE IF NOT EXISTS runs (
  id                 UUID PRIMARY KEY REFERENCES entities(id) ON DELETE CASCADE,  -- = E_run
  project_id         UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  snapshot_id        UUID NOT NULL REFERENCES snapshots(id) ON DELETE CASCADE,
  core_delegation_id UUID NOT NULL,                -- D_core (run-root → CORE root)
  name               TEXT NOT NULL,
  qualified_name     TEXT NOT NULL,
  args               JSONB NOT NULL,
  state              TEXT NOT NULL,                -- 'running' | 'cancelling' | 'done' | 'error'
  cancel_reason      TEXT,                         -- 'user' | 'error' | NULL
  result             JSONB,
  error_message      TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at       TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS runs_project_idx  ON runs (project_id);
CREATE INDEX IF NOT EXISTS runs_snapshot_idx ON runs (snapshot_id);
CREATE INDEX IF NOT EXISTS runs_state_idx    ON runs (state);
CREATE UNIQUE INDEX IF NOT EXISTS runs_core_delegation_idx ON runs (core_delegation_id);
CREATE INDEX IF NOT EXISTS runs_project_state_created_idx
  ON runs (project_id, state, created_at DESC);

-- The run's operator-facing escalations — both PENDING (`answer IS NULL`) and
-- ANSWERED. The API records one when an escalate reaches it, mapping the bus
-- `delegationId = D_core` → the run via `runs.core_delegation_id` (so the API
-- reads only its OWN tables — no walk into CORE's entity/delegation rows). The
-- live `escalations` row (raiser/hop-owned, for cascade) is CORE's; this is the
-- API's per-run operator view + history. In-CORE-handled escalations never reach
-- the API, so they aren't recorded here.
CREATE TABLE IF NOT EXISTS run_escalations_audit (
  run_id        UUID NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  escalation_id UUID NOT NULL,
  agent_def_id  JSONB NOT NULL,
  args          JSONB NOT NULL,
  answer        JSONB,                          -- null while pending
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  answered_at   TIMESTAMPTZ,                    -- null while pending
  PRIMARY KEY (run_id, escalation_id)
);
CREATE INDEX IF NOT EXISTS run_escalations_audit_esc_idx
  ON run_escalations_audit (escalation_id);

-- FFI Module's private sidecar relay state (ext-call inbound / ext-spawned
-- children / escalation relay map). Operational bookkeeping for the per-snapshot
-- sidecar, distinct from the protocol entity layer; the tree assembler does not
-- read these (entities is the SSoT for the execution tree).
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

-- Per-project env store. Each project owns its own key/value space (keyed by
-- project_id); shared across that project's snapshots (env outlives any single
-- deploy). `value` holds plaintext for non-secret entries and AES-GCM ciphertext
-- for secret entries; the EnvModule encrypts/decrypts at its boundary so storage
-- never sees plaintext credentials.
CREATE TABLE IF NOT EXISTS env_entries (
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  key        TEXT NOT NULL,
  value      TEXT NOT NULL,
  is_secret  BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, key)
);

-- ─── Value store: refs (entity-owned handles) + value_blobs (refcount ledger) ─
--
-- All byte sequences (`string` / `file` / `secret` / `closure`) are
-- content-addressed. Two layers:
--   - refs        : a handle owned by exactly one entity (`owner_entity_id`).
--                   Unifies the old ephemeral value_refs AND persistent api_files
--                   — there is no separate file table. A ref persists iff its
--                   owner is an entity the API keeps (a project / run root).
--   - value_blobs : project-wide content-addressed refcount LEDGER (the dedup
--                   unit). The BYTES live in a pluggable BlobStore (local FS /
--                   S3), keyed by (project_id, hash); Postgres keeps only this
--                   ledger. Freed (BlobStore delete) at refcount 0.
--
-- `ref = a module's handle, blob = the file's bytes`. A blob is NAMELESS (keyed
-- by hash, deduped); the file NAME is `refs.display_name` (ref-local metadata).

-- Content-addressed refcount LEDGER. ref_count is maintained by the trigger
-- below (incremented on produce by the value store, decremented on every ref
-- DELETE — explicit or entity cascade). 0 => bytes are deleted from the
-- BlobStore (post-commit). Project-scoped via (project_id, hash).
CREATE TABLE IF NOT EXISTS value_blobs (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  hash              TEXT NOT NULL,
  total_size        BIGINT NOT NULL,
  ref_count         INTEGER NOT NULL DEFAULT 0,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_accessed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, hash)
);

-- A blob handle owned by exactly one ENTITY (`owner_entity_id`, FK CASCADE: an
-- entity delete drops its still-owned refs → trigger decrements the blob
-- refcount). A delegation NEVER owns a ref — it is a request edge, not an owner.
--
-- ASCENT is value-driven, cross-server-clean (no entity-id on the bus, no
-- child↔parent table read, no parent lookup):
--   - a child produces refs owned by its own entity `E_child`;
--   - on terminal it DETACHES its ESCAPING refs (the result value's, transitively
--     via `refs_to`) by setting `owner_entity_id = NULL` (an in-transit ref,
--     owned by nobody), then self-deletes `E_child` (the rest cascade away);
--   - the parent, on the result ack, already HOLDS the result value — which
--     carries the very ref handles `{module,id}` — so it CLAIMS exactly those
--     refs (transitively via `refs_to`) by id, setting `owner_entity_id =
--     E_parent` (its OWN entity, known locally), then deletes the delegation.
-- The result value itself is the handoff vehicle; neither side queries the
-- other. `owner_entity_id IS NULL` is the brief (sub-second) in-transit state;
-- crash orphans are reaped by the boot sweep (no while-live NULL sweep). Because
-- the FK forbids a ref pointing at a non-existent entity, there is no "dead
-- owner" state to reconcile — NULL is the only orphan shape.
--
-- The wire ref is `{module, id}`; `module = 'api'` = owned by an API entity the
-- API keeps (a user upload on the project root, a run result on the run root).
-- Lifetime/durability has a SINGLE source of truth: ownership. A durable project
-- file is just a `file` ref owned by the project-root entity (id = project id) —
-- there is no separate durability flag. `display_name` is the file name (NULL for
-- program-/FFI-produced intermediates — names attach only at user upload).
-- `refs_to` is the closure adjacency so the detach/claim drag captures along.
CREATE TABLE IF NOT EXISTS refs (
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  module          TEXT NOT NULL,                 -- 'core' | 'ffi' | 'api' (produce origin / wire module)
  id              UUID NOT NULL,
  owner_entity_id UUID REFERENCES entities(id) ON DELETE CASCADE,  -- NULL = in-transit (mid-ascent)
  state           TEXT NOT NULL,                 -- 'complete' | 'errored'
  semantic_kind   TEXT NOT NULL,                 -- 'string' | 'file' | 'secret' | 'closure'
  refs_to         JSONB NOT NULL DEFAULT '[]',   -- [{module,id}] refs this ref captures (closures)
  hash            TEXT,                          -- -> value_blobs.hash (null while errored)
  size            BIGINT,
  content_type    TEXT,
  display_name    TEXT,                          -- human file name (= original upload name); null for intermediates
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, module, id)
);
-- (project_id, owner_entity_id) backs `listFiles` (durable files = project-root
-- owned) and the ascent's per-owner BFS.
CREATE INDEX IF NOT EXISTS refs_owner_entity_idx ON refs (project_id, owner_entity_id);
CREATE INDEX IF NOT EXISTS refs_hash_idx  ON refs (project_id, hash);

-- Keep the blob refcount correct under BOTH explicit ref deletes and entity
-- CASCADE: on every ref DELETE, decrement its blob's ref_count. (The value store
-- increments on produce.) The physical BlobStore delete is the caller's job
-- AFTER commit: it sweeps `value_blobs WHERE ref_count <= 0` and deletes those
-- bytes, so this trigger never does I/O.
CREATE OR REPLACE FUNCTION refs_decrement_blob() RETURNS trigger AS $$
BEGIN
  IF OLD.hash IS NOT NULL THEN
    UPDATE value_blobs SET ref_count = ref_count - 1
      WHERE project_id = OLD.project_id AND hash = OLD.hash;
  END IF;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS refs_after_delete ON refs;
CREATE TRIGGER refs_after_delete AFTER DELETE ON refs
  FOR EACH ROW EXECUTE FUNCTION refs_decrement_blob();
