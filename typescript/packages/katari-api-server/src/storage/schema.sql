-- katari-api-server schema. Apply once before first start.

CREATE TABLE IF NOT EXISTS module_versions (
  id            UUID PRIMARY KEY,
  name          TEXT NOT NULL,
  ir_module     JSONB NOT NULL,
  schema_bundle JSONB NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS agents (
  id              UUID PRIMARY KEY,
  delegation_id   UUID UNIQUE NOT NULL,
  version_id      UUID NOT NULL REFERENCES module_versions(id),
  qualified_name  TEXT NOT NULL,
  args            JSONB NOT NULL,
  state           TEXT NOT NULL,
  result          JSONB,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agents_version_state_idx ON agents (version_id, state);
CREATE INDEX IF NOT EXISTS agents_delegation_idx ON agents (delegation_id);

CREATE TABLE IF NOT EXISTS machine_snapshots (
  version_id UUID PRIMARY KEY REFERENCES module_versions(id),
  snapshot   JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Append-only diff log per version. Each row is one applyEvent's
-- emitted Diff[] (Phase G). Recovery may replay these against an
-- empty state to reconstruct, in addition to (or instead of) loading
-- machine_snapshots.
CREATE TABLE IF NOT EXISTS machine_diffs (
  id         BIGSERIAL PRIMARY KEY,
  version_id UUID NOT NULL REFERENCES module_versions(id) ON DELETE CASCADE,
  batch      JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS machine_diffs_version_idx ON machine_diffs (version_id, id);
