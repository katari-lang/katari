# Storage schema 再設計 と API endpoint

> [overview](2026-05-30-overview.md) の D24-D28 の詳細。
> 現状 user 0 なので migration は考えず、 DB を一から階層に合わせて設計する。

## 1. 現状 DB の階層 audit

`katari-api-server/src/storage/schema.sql` を [overview](2026-05-30-overview.md) の
階層と照合した結果:

| table                | 現状 owner            | 不整合                                                  |
| -------------------- | --------------------- | ------------------------------------------------------- |
| `projects`           | (root)                | ✅ OK                                                    |
| `snapshots`          | project               | ✅ OK                                                    |
| `engine_checkpoints` | **snapshot**          | ❌ per-snapshot CORE state。 目標は per-project shard + currentSnapshot |
| `delegations`        | **snapshot** (cascade) | ❌ snapshot 削除で run 死亡。 目標は project-scoped         |
| `escalations`        | **snapshot** (cascade) | ❌ 同上                                                  |
| `runs_audit`         | **snapshot** (cascade) | ❌ 同上                                                  |
| `env_entries`        | **global (key のみ)** | ❌ project_id すら無い。 全 project 横断で共有             |
| `ffi_pending_*`      | snapshot              | ❌ per-project module へ統合                              |
| value / blob / ref   | (無し)                | ➕ 新規                                                  |

2 つの根本問題:

1. **env_entries が project すら持たない (global)** → 「ENV は project-scoped」 と矛盾
2. **run 系が snapshot cascade** → 「instance は snapshot を跨ぐ (Option A)」 と矛盾。
   snapshot を削除すると走っている run が巻き添えで消える

## 2. 再設計した schema (D28)

階層: **snapshot だけが project の直接の子**。 それ以外は論理的にはどこかの module の子
だが、 物理的には「project-scoped table + owner を表す column」 で表現する (= module ごとに
table を割らず、 owner_module / endpoint で partition)。 snapshot は「どの版か」 の参照に
格下げ (= cascade key ではない)。

論理的所有 → 物理 table の対応:

| 論理的所有       | 物理 table             | owner の表現                    |
| ---------------- | ---------------------- | ------------------------------- |
| project          | `projects` / `snapshots` | —                             |
| CORE の instance | `engine_shards`        | (project 内、 shard 単位)        |
| 全 module の live instance | `delegations` / `escalations` | `caller_endpoint` / `owner_endpoint` |
| API の instance 履歴 (= run) | `runs_audit`     | (API 専用 table)                |
| ENV の env var   | `env_entries`          | (ENV 専用 table)                |
| CORE/FFI の ephemeral ref | `value_refs`  | `owner_module` (core/ffi)、 reachability GC |
| API の persistent file | `api_files`      | (API 専用 table、 user 管理)     |
| 共有 bytes (= file 本体) | `value_blobs` / `value_blob_chunks` | project-wide、 hash dedup、 refcount |
| API の file      | `api_files` (record) + `value_blobs` (bytes) | API 専用 table、 user 管理 |

```sql
-- ── 階層 root ──────────────────────────────────────────────
CREATE TABLE projects (
  id          UUID PRIMARY KEY,
  name        TEXT NOT NULL UNIQUE,
  description TEXT,
  readme      TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE snapshots (
  id              UUID PRIMARY KEY,
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  ir_module       JSONB NOT NULL,
  sidecar_bundle  JSONB,
  schema_bundle   JSONB NOT NULL,
  message         TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── CORE engine state (per-project shard) ──────────────────
-- 旧 engine_checkpoints (per-snapshot) を置き換え。
-- project-local index: どの shard を load すべきか引くための軽量テーブル。
CREATE TABLE project_index (
  project_id  UUID PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE,
  payload     JSONB NOT NULL,        -- ProjectIndex (= delegations / pendingDelegateOut / escalationOwners)
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- agent instance = shard。 currentSnapshot で「どの版の code を走らせているか」 を参照。
-- snapshot 削除では cascade しない (= 走っている instance は明示 terminate で消す)。
CREATE TABLE engine_shards (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  shard_id          UUID NOT NULL,                 -- = root delegation id
  current_snapshot  UUID NOT NULL REFERENCES snapshots(id),  -- どの版 (RESTRICT: 走っている版は消せない)
  payload           JSONB NOT NULL,                -- EngineShard (encrypted)
  status            TEXT NOT NULL,                 -- 'active' | 'terminating' | 'completed'
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, shard_id)
);
CREATE INDEX engine_shards_snapshot_idx ON engine_shards (current_snapshot);

-- ── cross-module 操作の durable 記録 (outbox/inbox + audit) ──
-- すべて project-scoped。 snapshot ではなく project に cascade。
-- snapshot_id は「どの版で起動したか」 の参照に格下げ (cascade しない)。
CREATE TABLE delegations (
  id                   UUID PRIMARY KEY,
  project_id           UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  root_delegation_id   UUID NOT NULL,
  parent_delegation_id UUID,
  snapshot_id          UUID NOT NULL REFERENCES snapshots(id),   -- どの版 (参照のみ)
  caller_endpoint      TEXT NOT NULL,
  owner_endpoint       TEXT NOT NULL,
  agent_def_id         JSONB NOT NULL,
  args                 JSONB NOT NULL,
  state                TEXT NOT NULL,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX delegations_root_idx     ON delegations (root_delegation_id);
CREATE INDEX delegations_project_idx  ON delegations (project_id, state);

CREATE TABLE escalations (
  id                  UUID PRIMARY KEY,
  project_id          UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  delegation_id       UUID NOT NULL,
  root_delegation_id  UUID NOT NULL,
  snapshot_id         UUID NOT NULL REFERENCES snapshots(id),
  caller_endpoint     TEXT NOT NULL,
  receiver_endpoint   TEXT NOT NULL,
  agent_def_id        JSONB NOT NULL,
  args                JSONB NOT NULL,
  state               TEXT NOT NULL,
  value               JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX escalations_project_idx  ON escalations (project_id, state);

CREATE TABLE runs_audit (
  id              UUID PRIMARY KEY,        -- = root delegation id
  project_id      UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  snapshot_id     UUID NOT NULL REFERENCES snapshots(id),   -- どの版で起動したか
  name            TEXT NOT NULL,
  qualified_name  TEXT NOT NULL,
  args            JSONB NOT NULL,
  state           TEXT NOT NULL,
  cancel_reason   TEXT,
  result          JSONB,
  error_message   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ
);
CREATE INDEX runs_audit_project_idx ON runs_audit (project_id, state, created_at DESC);

-- ── ENV (project-scoped に修正) ────────────────────────────
CREATE TABLE env_entries (
  project_id  UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  key         TEXT NOT NULL,
  value       TEXT NOT NULL,         -- plaintext or AES-GCM ciphertext
  is_secret   BOOLEAN NOT NULL DEFAULT FALSE,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, key)
);

-- ── 3 層: ephemeral ref / persistent file / shared blob ───
-- run と delegation の関係と同じ: ephemeral な実体は reachability で消え、 永続 record は
-- API が管理し、 重い resource (blob) は dedup されて refcount で解放される。

-- (a) ephemeral ref: CORE/FFI の中間値。 reachability GC 対象。 file の identity = id。
CREATE TABLE value_refs (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  owner_module      TEXT NOT NULL,             -- 'core' | 'ffi'
  id                UUID NOT NULL,
  state             TEXT NOT NULL,             -- v0.1.0: 'complete' | 'errored' ('building'/'cancelled' は v0.2)
  semantic_kind     TEXT NOT NULL,             -- 'string' | 'file' | 'secret'
  owner_instance_id UUID,                      -- 紐づく shard (= instance 終了で sweep)
  hash              TEXT,                       -- → value_blobs.hash
  size              BIGINT,
  content_type      TEXT,
  error_message     TEXT,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, owner_module, id)
);
CREATE INDEX value_refs_instance_idx ON value_refs (owner_instance_id);
CREATE INDEX value_refs_hash_idx     ON value_refs (project_id, hash);

-- (b) persistent file: API 所有の record (runs_audit と同位置づけ)。 reachability GC の
-- 対象外。 user が明示削除するまで残る。 file value は ref(module=api, id=この id) を持つ。
CREATE TABLE api_files (
  project_id    UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  id            UUID NOT NULL,
  hash          TEXT NOT NULL,                 -- → value_blobs.hash
  size          BIGINT NOT NULL,
  content_type  TEXT,
  display_name  TEXT,                          -- UI 用 (= 元 file 名)
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, id)
);
CREATE INDEX api_files_hash_idx ON api_files (project_id, hash);

-- (c) shared blob: project-wide content-addressed bytes (= dedup の単位)。
-- ephemeral ref と api_files の両方から hash で参照される。 chunk で持つので大 file も
-- streamable。 ref_count = (reachable な value_refs) + (api_files) の hash 参照数。
-- 0 で物理 delete。 注: produce 中の bytes は DB に持たず host の in-memory buffer、 close で
-- ここに確定する (= per-chunk DB write なし)。 観測可能な building は v0.2。
CREATE TABLE value_blobs (
  project_id        UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  hash              TEXT NOT NULL,
  total_size        BIGINT NOT NULL,
  ref_count         INTEGER NOT NULL DEFAULT 0, -- GC が維持 (reachable ephemeral + api_files)
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_accessed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (project_id, hash)
);
CREATE TABLE value_blob_chunks (
  project_id   UUID NOT NULL,
  hash         TEXT NOT NULL,
  chunk_index  INTEGER NOT NULL,
  bytes        BYTEA NOT NULL,
  PRIMARY KEY (project_id, hash, chunk_index)
);
```

注:

- `ffi_pending_delegations` / `ffi_pending_escalations` は `delegations` / `escalations` に
  統合 (= 元々 schema comment で予告されていた Phase 5)。 caller/owner endpoint で
  FFI 側 row を区別する
- `engine_shards.current_snapshot` は `ON DELETE RESTRICT` (= 走っている版の snapshot は
  消せない)。 snapshot 削除は「その版で走る instance を先に terminate」 を要求する
- **value の 3 層**: `value_refs` (ephemeral、 core/ffi、 reachability GC) / `api_files`
  (persistent、 user 管理) / `value_blobs` (= file 本体の bytes、 project-wide dedup、
  refcount)。 ref (= module の handle) と blob (= 共有 bytes) を分離。 run/delegation と同じ
  「永続 record + 解放可能な実体」 の構図 (D30)

## 3. value ref / agentLiteral から project を除去 (D24, D25)

project 間で値の受け渡しが無いので、 **project は ambient context** (= 「自分はどの
project runtime にいるか」) であり値の identity の一部ではない。

```ts
// data reference: (module, id) のみ。 project は ambient。
//   module=core/ffi → ephemeral (value_refs)、 module=api → persistent file (api_files)
{ kind: "ref"; module: "core"|"ffi"|"api"; id: string; hash; size; contentType? }

// code reference: (snapshot, qname)。 project は ambient
{ kind: "agentLiteral"; snapshot: string; qualifiedName: QualifiedName }
```

対称性:

| 参照種別                       | identity                | ambient |
| ------------------------------ | ----------------------- | ------- |
| data reference (bytes ref)     | (module, id)            | project |
| code reference (agentLiteral)  | (snapshot, qname)       | project |

data ref は「どの module の何番」、 code ref は「どの版の何」。 wire には project を
載せず、 fetch 時は「自分の project の module」 に問い合わせる。

## 4. API endpoint の 3 層分離 (D26, D27)

endpoint を 3 つの責務に分ける。 混同していたのを整理する。

### (1) Frontend endpoints — user/UI の代理 (ApiModule 提供)

HTTP の利便を考慮した convenience。 内部的には ApiModule が value protocol に変換する
adapter。 **file upload はここ** (= ApiModule が bytes を blob として produce し `api_files`
record を作る)。

```
POST   /project/:p/file                  upload → blob produce + api_files record (= file ref)
GET    /project/:p/file                  list (api_files)
GET    /project/:p/file/:id              download (= blob fetch)
DELETE /project/:p/file/:id              api_files row 削除 → blob refcount 減 → 0 で sweep

POST   /project/:p/run                   start run
GET    /project/:p/run                   list runs
GET    /project/:p/run/:rid              run details
POST   /project/:p/run/:rid/cancel       cancel
POST   /project/:p/escalation/:eid/answer
GET    /project/:p/snapshot              list / POST deploy
POST   /project/:p/env / GET             env 管理
GET    /project/:p/agent ...             agent listing
```

### (2) Cross-module protocol — Katari Protocol data plane (read-only, D27)

module 間通信の generic な data plane。 **read-only (consume)**。 file upload は無い
(= produce は module-internal)。 認証は module token。

```
GET /project/:p/value/:module/ref/:id              fetch bytes (complete blob)
GET /project/:p/value/:module/ref/:id?range=N-M    partial fetch (HTTP Range)
GET /project/:p/value/:module/ref/:id/state        metadata (state, hash, size)
```

v0.1.0 は complete blob の fetch のみ。 `subscribe` (= 完成前の chunk stream SSE) /
`await` (= terminal SSE) は observable streaming 用なので v0.2
([v0.2-streaming](2026-05-30-v0.2-streaming.md))。

sidecar はこの GET を `katari.value.fetch/text(arg)` 経由で叩く。 arg が `$ref` なら GET、
inline ならそのまま — handler は inline/ref を区別せず一律 `await` できる (= bytes を消費する
**await は FFI handler 内**、 CORE は ref を配線するだけ。 [implementation-plan Phase C](2026-05-30-implementation-plan.md))。

projectId が最外 (= どの project runtime に routing するか)、 module、 id の順。
snapshot は出ない (= value の owner ではない)。 multi-server 化したら projectId →
host の routing になる (= project が placement の単位)。

### (3) Module-internal produce — protocol ではない (各 module 自由)

produce は cross-module protocol に出さない。 各 module が自分の方式で:

- **FFI**: sidecar (別 process) が FFI module の produce endpoint を HTTP で叩く
  (= FFI module の実装詳細、 generic protocol ではない)
- **CORE / API / ENV**: in-process で直接 storage に書く

`bus` (control plane、 6 events) はこのどれとも別。 bus は 6 events、 data plane は
read-only HTTP、 produce は module-internal。 3 つが綺麗に分離される。

## 5. sweep ロジック

blob (= file 本体) の生死は `value_refs` (reachable な ephemeral) と `api_files` の両方から
hash 参照される数。 0 で物理 delete。

| trigger              | 動作                                                       |
| -------------------- | --------------------------------------------------------- |
| reachability GC       | CORE state walk で reachable hash を mark → 不参照 `value_refs` を delete |
| agent instance 終了   | `value_refs WHERE owner_instance_id=<dead>` を delete       |
| snapshot 削除         | その snapshot を current_snapshot に持つ instance を先に terminate → 上記 |
| project file 明示削除 | `api_files` row を delete                                  |
| (上記いずれか後)      | hash を指す `value_refs` + `api_files` が 0 → `value_blobs` delete |
| project 削除          | `project_id=<deleted>` 全 table cascade                    |

- **ephemeral** (`value_refs`) は reachability GC で消える (= traversal、 single-runtime 前提)
- **persistent file** (`api_files`) は user 明示削除のみ。 traversal 不要 (= 行を数えるだけ)
  なので multi-server でも安全。 traversal-bound なのは ephemeral だけ
- multi-server で「1 project を複数 server に分割」 する段 (v0.3+) では ephemeral の
  reachability traversal が成立しないので lease / incremental refcount に移行
  ([v0.2-streaming](2026-05-30-v0.2-streaming.md) の multi-server 節)

## 6. sidecar に渡す環境変数

```
KATARI_PROTOCOL_URL      = http://localhost:PORT     (data plane base)
KATARI_PROTOCOL_TOKEN    = <short-lived bearer>
KATARI_PROJECT_ID        = <projectId>
KATARI_SIDECAR_OWNER     = ffi                        (owner module 名)
```

projectId が分かれば `/project/:p/value/ffi/...` を組み立てられる。
