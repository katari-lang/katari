# Katari Runtime — ドメインモデルと schema (v0.1.0, scrap-and-build)

> 2026-06-15 の設計議論のまとめ。`scrap-and-build-v0.1.0` ブランチで runtime を
> 一から作り直すにあたっての概念モデル・所有/cascade・軽い DB schema・hono への
> 乗せ方を確定する SSoT。
>
> main の設計 doc (`2026-05-30-*`, `2026-06-01-entity-model`,
> `2026-06-08-scope-closure-entity`) を土台にしつつ、v0.1.0 向けに **大幅に単純化**
> した。主な差分はこのドキュメントの §0 に集約。

---

## 0. このブランチでの設計判断 (main からの差分)

| # | 判断 | main では | 理由 |
|---|------|-----------|------|
| R1 | **module / bus を撤廃。単一 CORE engine のみ** | CORE/FFI/API/ENV の 4 module + 6-event bus router | v0.1.0 は単一 process・単一 server。module 間 routing は不要な複雑さ |
| R2 | **ENV = primitive 操作** (engine 内 inline 実行) | ENV module への delegate | env lookup は project-scoped KV の bounded fetch。delegate するほどの物ではない |
| R3 | **FFI = external thread が直接 sidecar を叩く** | FFI module instance + ffi_pending_* | external leaf thread が suspend→resume の境界。instance ではない |
| R4 | **root instance は project に 1 つ**。その子として各 instance を召喚 | project-root entity + run-root entity の 2 段 | 単一 server なので親リンクを直接持てる。2 段に分ける必要なし |
| R5 | **値 = blob + 参照値の 2 軸**。dedup/refcount を廃止し blob は instance 所有 | ref(handle, instance 所有) / blob(bytes, content-addressed, refcount, dedup) の 2 層 | dedup は over-engineering。blob を instance 所有にし escape 時に ascent (closure と同じ) |
| R6 | **所有 (single-owner, CASCADE) と 捕捉 (capture, 参照) を明確に分離** | scope/closure とも entity 所有だが capture 関係の位置づけが曖昧 | Closure↔Scope に所有辺は無い。両者とも Instance が所有、間にあるのは capture 参照のみ (§4) |
| R7 | **single-server なので parent を実 FK で持つ** (off-server 配慮を撤回) | entity に parent を持たせず `D→E` map で復元 | multi-server (v0.2+) でないので素直に `parent_instance_id` を張れる |

単一 server / 単一 CORE を前提に倒したことで、main の「分散システムとしての正しさ」
配慮 (cross-server ascent handshake, off-bus entity id, module 別 tx) はほぼ不要になり、
モデルが大きく縮む。multi-server は v0.2 で再導入する場合に、6-event protocol を
process 境界に切り直す形で additively に戻せる (protocol の形は保つ)。

---

## 1. 階層

**Project が全ての親**。その直接の子は Snapshot (code version) と Instance ツリーの
root だけ。

```
System (host process)
  └─ Project ─────────────── isolation boundary / 永続 / 明示削除まで
       ├─ Snapshot ───────── code version = IR modules + schema + sidecar bundle
       └─ root Instance ──── project に 1 つ (parent = null)
            ├─ Instance ──── run の root agent (user が起動)
            │    └─ Instance ── その agent が呼んだ別 agent (= 子 activation)
            │         └─ …
            └─ Instance ──── 別の run
```

3 軸の lifecycle:

| 軸 | 単位 | lifecycle |
|----|------|-----------|
| **project** | isolation boundary | 明示削除まで |
| **snapshot** | code version | project 内に複数版。instance は `current_snapshot` で参照 |
| **instance** | 実行中の agent activation | delegate で起動 → terminal で消滅 |

---

## 2. 2層の対称構造 (組織原理)

system は **「Instance 間」と「Instance 内」の 2 層**から成り、両者は **同型の
request/reply protocol** を持つ。これが全体の組織原理。

### Instance 間 (engine が instance をまたいで処理)

外部イベント 6 種。instance = persist/quantum の単位なので、これらは persist 境界を
またぐ。

```
delegate  / delegateAck    召喚 + 結果
escalate  / escalateAck    capability 要求 (上昇) + 応答
terminate / terminateAck   破棄 + ack
```

### Instance 内 (1 instance = 1 thread ツリー)

内部イベント 6 種。1 instance の thread ツリー内に閉じ、persist 境界をまたがない。

```
call   / callAck     子 block の起動 + 完了        (旧 create / done を改名)
ask    / askAck       親への要求 (return/break/next/request) の上昇 + 応答
cancel / cancelAck    破棄 + ack
```

### 対称性

```
内部 (intra-instance, thread 間)      外部 (inter-instance)
  call     / callAck      ⟷     delegate  / delegateAck
  ask      / askAck       ⟷     escalate  / escalateAck
  cancel   / cancelAck    ⟷     terminate / terminateAck
```

**`OperationDelegate` は常に外部 `delegate` (新 instance を召喚)**。`BlockAgent` を呼ぶ
この op は、target が named (`CalleeName`) でも closure (`CalleeValue`) でも **区別なく
delegate** する。delegate の target は **`(qualifiedName, snapshot)` | closure 参照** の
いずれか。`OperationCall` (構造ノード: match/for/handle/parallel) **だけ**が内部 `call`
(同 instance 内に thread spawn)。

→ つまり **Instance = 1 つの `BlockAgent` activation**。その thread ツリーに居るのは
構造ノードだけで、agent / closure 呼び出しは全て子 instance になる (main の per-agent
shard と同じ細粒度。closure 呼び出しを in-shard 特別扱いする最適化は採らず、一様に
delegate)。closure を delegate できるのは scope が CORE-global per-project store にあり、
新 instance の body scope を captured scope に親リンクできるから (serialize 不要)。

v0.1.0 は単一 CORE engine なので、外部イベントも内部イベントも**同じ engine の
event queue** が処理する (module bus は無い)。外部/内部の区別は process 境界ではなく
**instance (ownership / load の単位 = shard) の境界**を意味する。commit / quantum の
境界はまた別で、effectful leaf delegation で起きる (IR の通り) ので、1 quantum 内に
複数 instance が生成されることもある。

---

## 3. 概念 (ドメイン知識)

### Project
deploy / isolation の最上位単位 (1 project = 1 app)。`id, name, description, readme`。
project 削除で配下を全 cascade (snapshots / instances / env / blobs / …)。通常運用では
ほぼ削除しない。

### Snapshot
code version。deploy するとその版の IR module 群 + schema + sidecar bundle が確定する。
**project の唯一の直接の子**。instance は `current_snapshot` でどの版で走るかを参照
(削除は RESTRICT 相当: 走っている版は消せない / 先に instance を terminate)。

### IR / Block
compiler の出力 (`Katari.Data.IR`)。`BlockAgent` が唯一の value-addressable callable
(呼び出し規約 + schema を持つ)。runtime は snapshot から IRModule を読み、`QualifiedName`
→ `BlockId` を `entries` で解決して thread を起こす。**runtime は IR を変更しない**
(読むだけ)。

### Instance (旧 Entity)
**cross-instance 実行ツリーのノード**。delegate で召喚され、scope / blob (案1 では
closure も) を **所有**する単位であり、**persist (load/checkpoint) の単位 (= shard)**
でもある。

- 1 instance = 1 `BlockAgent` activation = 1 thread ツリー。
- thread ツリーの中身は **構造ノード (`OperationCall`: match/for/handle/parallel) の
  thread だけ**。
- **agent / closure 呼び出し (`OperationDelegate`) は全て子 instance を召喚** (新ツリー)。
  in-shard 特別扱いは無い (§2)。
- **instance 自体は snapshot を属性として持たない**。「どの版か」は instance を起動した
  agent 参照 `(qualifiedName, snapshot)` 側の性質 (instance → 起動 → agent@snapshot)。
  起動 target を記録するので IR 解決時に snapshot は導出できる (R4 系の微差)。
- state: `running | cancelling`。`completed`/`error` は instance の状態ではなく **Run**
  (API の管理レコード) が持つ (§Run)。
- lifecycle: **explicit** (terminal で self-delete)。crash backstop として project cascade。
- single-server なので `parent_instance_id` を実 FK で持つ (R7)。

### Thread
Block の実行中インスタンス。engine が schedule / checkpoint する最小単位。内部イベント
(call/callAck/ask/askAck/cancel/cancelAck) で親子間を通信。kind ごとに variant
(agent / structural / delegate(proxy) / handle / for / …)。所有: Instance (CASCADE)、
lifecycle は explicit (完了で消える)。

### Scope
字句束縛ツリーのノード。`parentId` で親 scope へ繋がり、変数解決は親鎖を walk。
**Instance が所有** (CASCADE)。intra-instance GC で回収されることもある (§4)。
`ambientGenerics` (enclosing activation の generic 置換) を root scope に持つ。

### Variable
Scope 内の値スロット (`VariableId → Value`)。**Scope が所有** (scope 削除で消える)。
実体は scope の値マップなので、別テーブルにするか scope 内 JSON にするかは正規化粒度の話 (§6)。

### Closure
`BlockAgent` 本体 (`blockId`) と捕捉した scope の組。closure 呼び出しも
`OperationDelegate` = 子 instance を召喚 (§2、in-shard ではない)。delegate target は
closure 参照。

**表現は 2 案あり (要確定、§6)**:
- **案1**: `(blockId, scope)` を DB の `closures` 行に保存し id を付与、値は `{ closureId }`。
  closure は instance 所有の owned resource (CASCADE/ascent の対象)。
- **案2 (推奨)**: closure を独立 entity にせず、値として `{ blockId, scopeId(, snapshot) }`
  を直接持ちまわす。owned resource は **Scope だけ** に縮み、ascent/GC は脱出値の中の
  scopeId を辿るだけ。`closures` table 不要。closure 値が block を解決するため snapshot を
  ambient か値に持つ。

どちらでも captured **scope** は owned resource (§4) として残り、closure 値が instance
境界を脱出すると、その scope 鎖が **ascent** で親 instance に上がる。

### Delegation
親が子 instance を召喚した「**リクエスト辺**」の durable 記録 (発行元 = 親が管理)。
crash recovery 用の outbox。bus を流れる相関 id。state: `running | cancelling`。
ack 受信で発行元が削除。entity と lifetime が nest する (delegation ⊇ instance)。
> 単一 server では `parent_instance_id` を instance に直接持てるので、delegation table を
> 軽量化できる余地がある (§6 の検討事項)。

### Escalation
Instance が raise した capability 要求 (request / 制御フローの上昇)。**raiser instance が
所有** (CASCADE) — answer / cancel の権限ではなく **delete 権限が raiser にある**
(ancestor は answer 権限のみ)。state は `open` のみ (answer/cancel = 行削除)。in-CORE の
`handle` で捕まれば内部制御フロー (記録しない)。root instance まで上がった user-facing な
escalation は API が answer し、Run の audit に履歴を残す (§Run)。

### Blob + 参照値 (R5)
**値モデル = blob (bytes) と、そこを指す参照値 (Value 内の ref) の 2 軸**。

- **Blob**: 大きい bytes (大 string / file)。**Instance が所有** (CASCADE)。`hash`
  (content 比較・`string == string` 用)、`size`, `content_type`, `semantic_kind`
  (`string | file | secret`) を持つ。bytes は pluggable な BlobStore (FS/S3)。
  **dedup / refcount は持たない** (R5)。
- **参照値**: scope variable に載る Value の一種 (`{ kind: "ref", blobId, hash, size, … }`)。
  blob を指すだけ。

inline → blob 昇格は persist 専用 (閾値超の string を blob 化)。blob が結果 value に
乗って instance を脱出すると closure と同じく **ascent** で owner が上がる (= run 結果の
file が root instance に残り永続する)。

### Run (API の管理レコード)
user が起動した run の軌跡を API module が管理するレコード。instance の状態とは別:
- instance 自身の状態は `running | cancelling` のみ。
- **Run の状態** `running | cancelling | done | error` は、その run の **CORE root
  instance の子の結果**を反映 (delegateAck で done、throw で error)。
- `name, qualified_name, args, result, error_message, cancel_reason, snapshot_id,
  completed_at` + 追跡する `instance_id`。1:1 で run instance に対応。
- **escalations-audit**: answer 済みの user-facing escalation の履歴 (質問 + 回答 +
  その時点の file 引数)。

### Env
project-scoped な KV (`key → value`, `is_secret`)。secret は AES-GCM。ENV module は無く、
`get_env` / `set_env` は engine 内 primitive として inline 実行 (R2)。

### GC
2 種類:
- **intra-instance scope GC**: 長寿命 instance (大きい `for` / orchestrator) が貯める
  transient scope を回収。roots = その instance の生存 thread の scope 鎖 + その instance が
  所有し生存 value から到達可能な closure。**親 instance 所有 (継承/captured-from-ancestor)
  の scope には触らない** (それは root 扱い)。
- **cascade / ascent**: instance terminal で所有物を cascade drop、脱出するものは ascent で
  親へ。これは GC というより lifecycle (§4)。

---

## 4. 所有 / capture / cascade / ascent (R6)

**所有 (ownership) と 捕捉 (capture) は別の辺**。混同すると Closure↔Scope の関係が
曖昧になる。

### 所有 (single-owner, CASCADE を駆動)

常に `Resource → Instance` (single-owner)。これだけが cascade delete を駆動する。

```
Instance ─┬─ Scope            (CASCADE)
          ├─ Blob             (CASCADE)
          ├─ Thread           (CASCADE; 通常は explicit 完了)
          ├─ Escalation       (CASCADE; raiser 所有, 通常は explicit answer/cancel)
          └─ Closure          (案1 のみ。案2 では owned でなく値; §3 Closure)
Scope ──── Variable           (CASCADE; 実体は scope の値マップ)
project ── 全て               (CASCADE by project_id)
```

`Delegation` と `Instance` は explicit lifecycle で管理 (cascade の子ではなく、ack /
terminal で明示削除。project cascade は backstop)。

### 捕捉 (capture, 多対一の参照。所有ではない)

```
Closure ──capturedScopeId──▶ Scope
Scope   ──parentId────────▶ Scope (親)
Scope.values ─(nested)────▶ Closure / Blob (値の中の ref)
```

これは **GC の reachability** と **ascent の drag** に使う参照であって、所有ではない。

### なぜ Closure と Scope の間に所有辺が無いか

**Scope は共有されるから。** 1 つの scope は「そこで走る thread」「子 scope (parentId)」
「それを捕捉する複数 closure」から同時に参照される → 単一所有者を closure に決められない。
逆に Scope が Closure を所有するのも違う (closure は value として変数に載り結果で脱出、
scope 階層とは独立)。→ **所有者は Instance に集約。Closure と Scope は互いに所有せず、
両者とも Instance が所有し、間にあるのは capture 参照のみ。**

### Ascent (owner lift, value-driven)

closure / blob value が instance 境界を脱出 (`delegateAck` / `escalate` の payload に乗る)
した時:

1. 脱出する値から **capture 辺を辿った到達可能集合**を計算 (closure → `capturedScopeId`
   → `parentId` 鎖 → scope 値内の nested closure / blob、を transitively)。
2. その集合の `owner` を `NULL` に detach (in-transit) してから、instance を self-delete
   (残りの所有物は cascade)。
3. 親 instance が結果 value を受け取った側で、value から同じ到達可能集合を計算し `owner`
   を自分に **claim**。

**不変条件**: closure / blob とそれが捕捉する scope 鎖は常に同じ owner (in-transit の
一瞬を除く)。到達可能なものは一緒に動く。これが「closure が scope を連れて上がる」の正体
だが、所有ではなく reachability drag。

run 結果の file (blob) が永続するのも同じ: 結果として脱出 → run instance から detach →
root instance が claim → root は明示削除されないので永続。

---

## 5. hono への乗せ方 / service モデル適合性

runtime には性質の違う 2 種類のコンポーネントがあり、scaffold の
`routes / service / repository / table / schema` パターンへの適合度が異なる。

### (1) stateless HTTP リソース — scaffold にそのまま乗る ◎

frontend API。request/response の CRUD + 起動トリガ。`routes → service → repository`
にそのまま乗る。

| リソース | 操作 |
|----------|------|
| Project | create / list / get / delete |
| Snapshot | deploy (IR bundle upload) / list / get |
| Run | start / list / get / cancel |
| Escalation | list (open) / answer |
| File (blob) | upload / download / list / delete |
| Env | get / set / list / delete |
| Agent | list (snapshot の schema を返す) |

### (2) stateful engine + actor — façade のみ △

Instance / Thread / Scope / Closure / engine event は stateless service には乗らない。
**warm な per-project actor (durable object 風)**。ただし façade として薄い service
interface (`feed(event)`, `startRun`, `cancel`, `answerEscalation`) を持ち、HTTP service
層からはそれを呼ぶ形で隠蔽する。

| コンポーネント | service 適合 | 形 |
|----------------|--------------|----|
| HTTP リソース (上記) | ◎ そのまま | routes → service → repository |
| Engine (instance graph 操作) | △ façade のみ | warm actor、service は薄い入口 |
| Blob store | ○ | repository 相当 (FS/S3 backed) |
| Engine state repository | ○ 特殊 | per-instance graph の load/persist (per-row CRUD ではない) |
| ProjectActor (serial loop, warm) | ✕ | hono の外、module-scope の `Map<projectId, actor>` |

### 接続と warm actor の住まい

```
runs.routes ─→ runs.service.start()
                 └─→ runtime.feed({ delegate, ... })     ← engine façade
                       └─→ ProjectActor (serial loop)     ← Map<projectId, actor> @ module scope
                             └─→ engine (quantum 実行)
                                   └─→ engineRepository.load/persist(instance graph)
```

- **HTTP service 層が IO 表面、actor が stateful core。** これは「IO 表面を先に固める」
  実装方針 (実装計画 doc) に綺麗に合う: service interface + zod IO schema + repository
  signature を stub で先に確定し、engine 内部を後で埋める。
- toolchain は Node 常駐 process ([[project_ts_toolchain]]) なので、`Map<projectId,
  ProjectActor>` を module scope に warm 保持できる。最初の event で lazy reactivate、
  DB が truth。serial loop は per-project の in-process async queue。
- hono の標準構成 (`createApp()` factory + middleware + `/api/v1` route + zValidator)
  はそのまま。runtime は `src/runtime/` に actor/engine/value を置き、HTTP は
  `src/modules/<resource>/` に scaffold パターンで置く。

---

## 6. 軽い schema (light, 3NF + JSON leaves)

cross-instance メタデータは素直な 3NF。engine graph は **構造 = 3NF / 葉 = 型付き JSON**
(Value は record/array/ref の再帰木なので relational 化せず JSON column に留める。完全
EAV 化はしない)。`⌫` = `ON DELETE CASCADE`。

```sql
-- ── hierarchy ──────────────────────────────────────────────
projects(id, name UNIQUE, description, readme, created_at)
snapshots(id, project_id→projects ⌫, modules JSONB, sidecar_bundle JSONB,
          message, created_at)   -- IR を 1 構造化 blob で (moduleName→IRModule)。schema は IRModule.schemas 内

-- ── 実行ツリー (single-server: 実 parent FK) ───────────────
instances(
  id, project_id→projects ⌫,
  parent_instance_id→instances ⌫,    -- null = project root
  delegation_id,                      -- 召喚した delegation (null = root)
  target JSONB,                       -- 起動した agent 参照: (qname, snapshot) | closure 参照。
                                      --   snapshot はこの target の性質 (instance の属性ではない)
  snapshot_id→snapshots,              -- target から導出した版 (FK/RESTRICT/index 用の denormalize)
  status,                             -- running | cancelling | completed
  created_at, updated_at
)

-- ── engine graph (instance 所有, CASCADE) ──────────────────
threads(project_id, instance_id→instances ⌫, thread_id,
        kind, parent_thread_id, scope_id, status,
        payload JSONB,                -- kind 別 variant data (葉)
        PK(project_id, instance_id, thread_id))
scopes(project_id, scope_id, parent_scope_id,
       owner_instance_id→instances ⌫, ambient_generics JSONB,
       PK(project_id, scope_id))
scope_variables(project_id, scope_id, var_id,
       value JSONB,                   -- Value 木 (葉; ref を含みうる)
       PK(project_id, scope_id, var_id))
closures(project_id, closure_id, block_id, captured_scope_id,  -- 案1 のみ。案2 では table 不要
       owner_instance_id→instances ⌫,                         --   (closure は scope_variables の値内に inline)
       PK(project_id, closure_id))
blobs(project_id, blob_id, owner_instance_id→instances ⌫,  -- owner NULL = in-transit (ascent)
       hash, size, content_type, semantic_kind, created_at,
       PK(project_id, blob_id))       -- bytes は BlobStore (FS/S3)

-- ── request / capability 辺 ────────────────────────────────
delegations(id, project_id→projects ⌫, caller_instance_id→instances,
       target JSONB, args JSONB, state, created_at, updated_at)
escalations(id, project_id→projects ⌫, raiser_instance_id→instances ⌫,
       agent_def JSONB, args JSONB, state, created_at)  -- state = open のみ

-- ── API 管理 ───────────────────────────────────────────────
runs(id, project_id→projects ⌫, instance_id→instances, snapshot_id→snapshots,
       name, qualified_name, args JSONB, state,
       result JSONB, error_message, cancel_reason, created_at, completed_at)
run_escalations_audit(run_id→runs ⌫, escalation_id,
       question JSONB, answer JSONB, answered_at)

-- ── env ────────────────────────────────────────────────────
env_entries(project_id→projects ⌫, key, value, is_secret, updated_at,
       PK(project_id, key))

-- ── in-flight external (FFI) call — crash recovery 用 ──────
external_calls(id, project_id→projects ⌫, instance_id→instances ⌫,
       thread_id, key, args JSONB, state, created_at)
```

### 検討事項 (実装中に詰める)

- **engine graph の persist 粒度**: 上記は「行ごと (threads/scopes/closures/variables を
  別行)」= 構造 3NF。利点 = partial load・admin-web で覗ける・blob 巨大書換なし。代償 =
  quantum 末尾に dirty 行を tracking して upsert する複雑さ。代替案は「instance ごとに
  1 JSONB payload」(main 踏襲・最も単純・atomic だが 3NF でない)。**「なるべく 3NF」方針に
  従い行ごとを採用予定**だが、hot path の persist 実装で重ければ instance 単位 JSONB に
  退避できる (schema 互換性は気にしない)。
- **closure の表現 (案1 / 案2)**: §3 Closure 参照。**案2 (closure を独立 entity にせず値
  `{ blockId, scopeId(, snapshot) }` で持ちまわす) を推奨**。owned resource が Scope に
  一本化され `closures` table が消える。確定したら上記 schema から `closures` を削除する。
- **scope_variables を独立行にするか scope 内 JSON にするか**: 完全行展開は変数アクセスが
  細粒度になりすぎる可能性。`scopes.values JSONB` に畳む案も可。
- **delegation table を残すか**: single-server で `instances.parent_instance_id` を実 FK で
  持てるので、delegation の「リクエスト辺」記録は crash recovery の outbox としてのみ
  必要。instance の status + parent link で代替できるか実装時に判断。
- **blob bytes の置き場**: BlobStore 抽象 (FS / S3) に逃がす。DB の bytea で持つ簡易案も可。

---

## 7. v0.2+ に送るもの

- multi-server (project affinity / LRU eviction / cross-server ascent handshake)
- observable streaming (building ref / mid-stream subscribe / valueReady internal event)
- snapshot migration (instance の `current_snapshot` 付け替え)
- module の process 分割 (6-event protocol を process 境界に切り直し)
