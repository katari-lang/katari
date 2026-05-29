# 実装 plan

> [overview](2026-05-30-overview.md) の設計を実装に落とす phase 分割。
> これは streaming/blob 機能追加ではなく runtime / api-server の全体リファクタ。
>
> **v0.1.0 スコープ**: 値モデル (blob = complete ref) + actor/shard refactor + DB 再設計。
> observable streaming (mid-stream consume / building / live 出力) は v0.2 に分離
> ([v0.2-streaming](2026-05-30-v0.2-streaming.md))。

## Phase 一覧

```
A (Value 型 rewrite — blob のみ)
  └─→ B (Storage 再設計 + value store (complete blob) + data plane HTTP)
        ├─→ C (FFI / sidecar produce-consume)  ┐
        ├─→ D (Runtime semantics: == / match / prim)  ├ B 後に並列可
        └─→ E (Actor host + per-agent shard) ┘ ← 最重量、 engine 全体に波及
              └─→ F (Frontend / API module / admin web)
                    └─→ G (GC + recovery)
                          └─→ H (stdlib AI agents + Discord BOT sample)
```

| Phase | 内容                                          | LOC   | 工数  | v0.1.0 |
| ----- | --------------------------------------------- | ----- | ----- | ------ |
| A     | Value 型 rewrite (blob) + codec + file 型      | 700   | 1 週  | ✅      |
| B     | DB 再設計 + value store (complete blob) + data plane | 1400 | 2 週 | ✅    |
| C     | FFI / sidecar produce-consume (complete)       | 900   | 1.5 週 | ✅      |
| D     | == / match / prim materialize + file/string 分岐 | 800 | 1 週  | ✅      |
| E     | actor host + per-project module + shard 分割    | 2200  | 3 週  | ✅      |
| F     | frontend API + admin web files                 | 700   | 1 週  | ⚠ 部分 |
| G     | blob GC (reachability) + crash recovery        | 700   | 1 週  | ⚠ 部分 |
| H     | stdlib AI agents + Discord BOT sample          | 700   | 1.5 週 | ✅      |

合計 ~8100 LOC、 順次 12 週、 並列圧縮で 8〜10 週。 (streaming を v0.2 に外した分、 縮小)

---

## Phase A: Value 型 rewrite

**対象**: `katari-runtime/src/engine/value.ts`, `value-codec.ts`, `value-secret-codec.ts`,
`engine/snapshot.ts`, `katari-types/`、 言語側 (`Katari.Common` / `SemanticType` / `Stdlib`)。

**deliverables**:

1. 新 `Value` 型 + `BytesRep` (inline / ref) — [value-and-streaming §5](2026-05-30-value-and-streaming.md)
2. `string` / `file` / `secret` を `rep: BytesRep` に。 `file` primitive 型を言語に追加
3. `agentLiteral` に `snapshot` field 追加
4. RawValue codec ([value-and-streaming §11](2026-05-30-value-and-streaming.md)):
   `$ref` envelope 追加 (`{$ref:{module,id}, as, hash, size, contentType?}`)、 `$agent` に
   snapshot、 decode routing に `$ref` 追加。 `valueToRaw` は **as-is、 sync のまま**
   (= ref を materialize せず `$ref` を emit、 昇格しない)。 `valueFromRaw` も sync
   (`$ref` → `{kind: as, rep: ref}`)
5. **昇格は persist 専用**: `snapshot.ts` (shard serializer) を async 化し、 threshold 超の
   inline byte-sequence を owner=core ref に昇格 (blob 書き込み)。 VALUE_KIND_TAGS 更新、
   secret 暗号化を BytesRep 対応に
6. `Katari.Schema`: string は `type:string` のまま (= union にしない)、 file は `$ref` schema。
   `schema-validate` を **Value × SemanticType (kind 検証)** に変更 (= rep 直交、 ref を透過、 §12)
7. `materializeBytes(rep, ctx)` の interface 定義 (実装は D)
8. `string == string` (content) / `file == file` (identity) の prim 分岐、
   `file_to_string` / `string_to_file` / `persist` prim 宣言

**完了基準**: 既存 e2e サンプル 22 個が通る (= ref 化しても観測挙動が変わらない)。
**risk**: secret-codec が `string` を仮定。 BytesRep 対応で慎重に。

## Phase B: Storage 再設計 + value store (complete blob) + data plane

**対象**: `katari-api-server/src/storage/` (schema 全面書き換え), `katari-runtime/src/storage/`
(新規 interface), `katari-api-server/src/routes/value.ts` (新規)。

**deliverables**:

1. schema 再設計 — [storage-schema-and-api §2](2026-05-30-storage-schema-and-api.md)
   (project-scoped env / delegations / runs、 engine_shards、 3 層 value: `value_refs`
   ephemeral / `api_files` persistent / `value_blobs`+chunks 共有)
2. `ValueStore` interface + Postgres impl + memory impl:
   - produce: `putComplete(owner, bytes, opts) → {id, hash, size}` /
     `open → pushChunk* → close → {id, hash, size}` (= 大 file 用、 produce 中は host buffer)
   - consume: `getState(owner, id)` / `fetch` / `fetchRange` (ref → hash → blob)
   - file: `createFile` / `listFiles` / `deleteFile` (= api_files)
   - GC: `markReachable` (ephemeral) / blob `sweep` (hash 参照 0)
3. produce 中の bytes は host の in-memory buffer、 close で hash 計算 → dedup or
   `value_blobs` + `value_blob_chunks` に確定 (= per-chunk DB write なし、 D32)
4. data plane HTTP routes (read-only consume: fetch / range / state) —
   [storage-schema-and-api §4](2026-05-30-storage-schema-and-api.md)。 subscribe / await は v0.2
5. hash = Blake3。 produce 中の buffer 上限 (例 100MB) 超過で error

**完了基準**: ValueStore unit test (putComplete / open-push-close / dedup / fetch / range)、
data plane integration test (GET / range)。

## Phase C: FFI / sidecar produce-consume (complete)

**対象**: `katari-runtime/src/modules/ffi.ts`, `sidecar/sidecar-manager.ts`,
`katari-port/src/index.ts`, `types.ts`。

**deliverables**:

1. sidecar spawn 時の env — [storage-schema-and-api §6](2026-05-30-storage-schema-and-api.md)
2. katari-port 新 API (complete blob を produce / consume):
   ```ts
   // consume — arg が inline でも ref でも一律 await できる
   katari.value.fetch(v: RawValue): Promise<Uint8Array>   // $ref → data plane GET、 inline → encode
   katari.value.text(v: RawValue): Promise<string>        // 同上、 UTF-8 decode
   katari.value.fetchRange(v, offset, length): Promise<Uint8Array>
   // produce
   katari.value.put(bytes, opts?) / open → push* → close   // ephemeral (default)
   katari.project.files.put / get / list                   // project-persistent
   katari.value.persist(ref)                               // ephemeral → persistent promote
   ```
   **consume の ergonomic**: handler args は `Record<string, RawValue>`。 大きいかもしれない arg
   (history 等) は `$ref` で来る、 小さいものは inline。 `katari.value.fetch/text` が **両方を
   受ける** ので、 handler は `const history = await katari.value.text(args.history)` と一律に
   書ける (= short conversation の inline でも long history の ref でも同じコード)。 これが
   「流れてきた ref から Promise を組む」 部分。 **await は基本 FFI handler 内** (= content を
   消費する側、 例: history を fetch → prompt 組立 → LLM)。 CORE は ref を配線するだけで
   materialize しない。
   produce 側: handler は produce してから `return ref` (= close まで delegateAck を返さない)。
   cancel は `ctx.signal` で既存 terminate cascade に乗る (= producer は delegation 内で完結)。
   mid-stream subscribe / detach は v0.2 ([v0.2-streaming](2026-05-30-v0.2-streaming.md))
3. crash / restart: sidecar 再起動で produce 途中だった ref を errored 化
4. 既存 11 IPC events は無変更。 value 関連は全部 HTTP data plane

**完了基準**: 新 e2e サンプル `23-blob-echo` (= sidecar が大きい blob を produce → CORE が
ref で受けて fetch → 値検証)。
**risk**: sidecar の HTTP fetch availability (Node 18+ で OK)。

## Phase D: Runtime semantics (materialize / == / match)

**対象**: `engine/prim.ts`, `pattern.ts`, `engine/value.ts` helpers。

**deliverables**:

1. `materializeBytes(rep, ctx)` (async): inline → 即 / ref(complete) → data-plane fetch を
   **inline await** (= bounded I/O)。 engine は async になるが deterministic (content hash の
   純粋関数) を保つ. v0.1.0 では ref が常に complete なので跨 quantum の suspend は不要
2. prim 更新: `string_length` / `file_size` (ref metadata で即返、 **fetch 不要**)、
   `equal_string` (両者 hash 比較、 **fetch 不要**) / `equal_file` (id 比較)、
   `string_concat` / f-string / `substring` (operand を **fetch** して新 ref produce)
3. MatchThread: string literal pattern は subject の hash と literal の hash を比較
   (**fetch 不要**)。 file は literal pattern 不可 (型エラー)
4. `file_to_string` (re-tag) / `string_to_file` (新 ref produce) / `persist`

**完了基準**: ref 値での == / match / concat / length の test (= fetch する/しないの双方)。
**注**: 跨 quantum の suspend (`valueReady` / `ref_terminated`) は v0.2 の無期限 building 待ち用
で v0.1.0 不要。 v0.1.0 の async は bounded fetch の inline await のみ。

## Phase E: Actor host + per-project module + shard 分割 (最重量)

**対象**: `engine/state.ts`, `snapshot.ts`, `modules/core.ts`, `apply.ts`,
`orchestrator/*`, `api-server/orchestrator-adapter.ts`。 engine host 層をほぼ rewrite。

**deliverables**:

1. `EngineShard` / `ProjectIndex` 型 ([runtime-architecture §9](2026-05-30-runtime-architecture.md))
2. 各 module の constructor を `snapshotId` → `projectId` に。 agent_def は各 module の
   子として持つ (CORE = `(snapshot, qname) → IR`、 FFI = `(snapshot, qname) → ext
   dispatch` + `snapshot → sidecar bundle`、 ENV = `qname → builtin op`、 snapshot 非依存)。
   `delegate` の agentDefId は受信 module が自分の registry で decode
3. event → 必要 shard 計算、 on-demand load、 dirty shard のみ persist
4. closure を shard-local registry に。 cross-shard call は originShardId で on-demand load
5. ProjectActor host: `Map<projectId, ProjectActor>`、 serial event loop、 per-module tx、
   `withSnapshotLock` 廃止 (= single-threaded actor)、 tx 失敗で actor evict
6. transaction を各 module 責務に ([runtime-architecture §6](2026-05-30-runtime-architecture.md))。
   cross-module は delegation table 経由の recovery
7. shard lifecycle: delegate で作成、 完了で即 delete (replay なし → retention 不要)

**完了基準**: 複数 agent 並走サンプル + per-shard write 確認、 既存 e2e 全 regression なし。
**risk**: engine 全体に波及。 着手前に詳細設計 doc を別途書く。 段階導入も検討。

## Phase F: Frontend / API module / admin web

**対象**: `api-server/routes/run.ts` 他, `katari-admin-web/`。

**deliverables**:

1. ApiModule に file frontend endpoint (upload を chunk で受けて value store に produce → close)
2. run args の file picker (project files から選択)
3. admin web の Value 表示: ref + size + contentType、 画像 inline preview
4. admin web に Files ページ (= ENV と並ぶ project-persistent resource 管理)

**完了基準**: admin web から画像 upload → agent 起動 → 結果確認。

## Phase G: GC + recovery

**対象**: `engine/gc.ts`, `api-server` の background worker。

**deliverables**:

1. CORE state walk で reachable ref id 集合を mark (= 既存 closure GC を拡張)
2. unreachable な ephemeral ref → delete → blob refcount 減算 → 0 で blob sweep
3. background worker: ephemeral 即 sweep、 persistent は user 削除待ち
4. snapshot 削除 cascade (= current_snapshot に持つ instance terminate → ephemeral sweep)
5. crash recovery: produce 途中の ref を errored 化、 delegation table から cross-module 再 drive

**完了基準**: blob GC unit test (reachability / dedup refcount)、 snapshot/project 削除
cascade test、 crash recovery test。

## Phase H: stdlib AI agents + Discord BOT sample

**対象**: stdlib モジュール群 + sidecar 実装 + `e2e/samples/`。

**deliverables**:

1. `katari.std.openai.chat` / `anthropic.messages` / `gemini.generate`
   (各 stateless provider 向け、 会話履歴を string/file ref で扱う。 handler は complete
   response を produce して ref を返す。 live token 出力が要れば handler 内で直接 Discord に
   post = FFI-internal streaming)
2. retry (失敗時の再試行) は stdlib agent / handler の責務 (= 言語 primitive ではない)
3. Discord BOT サンプル (= v0.1.0 のドッグフード)

**完了基準**: Discord BOT サンプルが file / 会話履歴 (ref) を使って動く。

---

## 着手順と注意

1. **Phase A から着手**。 Value rewrite が全ドミノの起点
2. **Phase E は着手前に詳細設計 doc を書く** (= engine 全体に波及、 invariant を固める)
3. C / D は B 完了後に並列可。 F は E 後半から並走可。 G は最後、 H は G と並走可
4. 各 Phase で既存 e2e サンプルの regression を確認しながら進める
5. 「最小変更」 は気にしない。 ideal な形に overwrite する (= user 0、 migration 不要)

## v0.1.0 の他マイルストーン (本リファクタ外、 別途)

- Formatter (定義間スペース / 改行 / 行頭スペース)
- per-module upload (= 更新 module だけ upload。 v0.2 送り候補)
- `agent def` / `agent` → `agent` / `run` rename ([[project_v0_1_0_rename_agent_run]])

## v0.2 送り (本リファクタの続き)

- **observable data streaming** (mid-stream consume / building state / live 出力) —
  [v0.2-streaming](2026-05-30-v0.2-streaming.md)。 reachability GC or explicit channel、
  detach、 producer cancel、 subscribe/await endpoint
- per-shard 並行 tick (= v0.1.0 は per-project serial loop)
- snapshot migration (= instance の currentSnapshot 付け替え)
- multi-server (= project affinity / single activation の分散)
- blob storage backend を Postgres bytea から FS / S3 へ
