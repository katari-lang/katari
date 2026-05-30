# Phase E 詳細設計 — actor host + per-project module + per-agent shard

> [implementation-plan](2026-05-30-implementation-plan.md) が「Phase E は着手前に詳細設計
> doc を書く」と要求する、その doc。[runtime-architecture](2026-05-30-runtime-architecture.md)
> (durable object の概念設計、D12-D23) を **現コードに対する具体的な実装手順**に落とす。
>
> **Phase E が unblock するもの**: E 自身に加え、Phase C の残り (sidecar env 配線) と
> Phase D の残り (async materialize) が両方 E に収束する (前者は per-project FfiModule、
> 後者は async quantum を要求するため)。

## 0. 現状コードの実測 (出発点)

設計判断の前提として、現コードを実測した結果:

| 項目 | 現状 | 含意 |
| --- | --- | --- |
| `Module.feed/persist/load` | **既に `Promise`** (async) | **bus / module 境界は既に async**。async 化は engine 内部だけ |
| engine `applyEvent / drive / step` | **完全 sync** | quantum 内 fetch のため async 化が必要 (D-async) |
| `State` (engine/state.ts) | **flat** (threads/scopes/closures/delegations/pendingDelegateOut/delegationSenders/escalationOwners + counters が全部 top-level) | shard 分割は flat State の再構造化 |
| `CoreModule` | `snapshotId` keyed、1 snapshot = 1 IRModule = 1 flat State | per-project + multi-snapshot 化が必要 |
| `Orchestrator.tick` | per-request、cold module を `TickModulesFactory` で都度構築、`withTransaction + withSnapshotLock`、drain、persist | warm ProjectActor に置換 |
| `CoreCheckpointStore` | `get/upsert(snapshotId)` で flat checkpoint 1 個 | shard 単位 + project index に分割 |
| `AgentDefId` | flat string (`qname` または `closure:N`)、受信 module が decode | 不変。snapshot 軸を別途付与 |

**最重要の発見**: module 境界は既に async なので、「engine を async にする」のは
`applyEvent → drive → step` を `async` にして `CoreModule.feed` が `await` するだけ。
ripple は engine + CoreModule + その test/recovery 呼び出し元に限定される。

## 1. ゴールと非ゴール

### ゴール (v0.1.0 で E がやること)

1. flat `State` を **per-agent `EngineShard` + project-local `ProjectIndex`** に分割
2. engine を **deterministic だが async** に (bounded fetch を quantum 内 inline await)
   → Phase D の `materializeBytes` + `concat`/`format` 等の ref operand fetch がここに乗る
3. `CoreModule` を **projectId keyed + multi-snapshot** に (agent_def = `(snapshot, qname) → IR`)
4. **event → 必要 shard のみ load**、dirty shard のみ persist (memory/IO の勝ち)
5. `Orchestrator.tick` を **`ProjectActor` host** (warm、single-activation、serial loop) に置換
6. transaction を各 module の責務に (`withSnapshotLock` 廃止)、cross-module は delegation table 経由の recovery
7. **sidecar env 配線** (Phase C 残り): per-project FfiModule が
   `KATARI_PROTOCOL_URL/_TOKEN/_PROJECT_ID/_SIDECAR_OWNER` を sidecar に渡す
8. `agentLiteral.snapshot` (Phase A で deferred) を付与

### 非ゴール (v0.2 送り)

- per-shard 並行 tick (v0.1.0 は per-project serial loop)。[[project_orchestrator_txref_deadlock]]
  の教訓から lock は保守的に
- 無期限待ち resume quantum (`valueReady` engine-internal event) — observable streaming 用
- multi-server の project affinity / LRU eviction
- snapshot migration (instance の currentSnapshot 付け替え) の実発火

## 2. データモデル: flat State → Shard + Index

現 flat `State` の各フィールドを以下に振り分ける ([runtime-architecture §9](2026-05-30-runtime-architecture.md)
の sketch と一致):

```ts
type ShardId = string;  // = top-level (root) delegation id = agent instance id

// 1 agent instance = 1 shard。需要に応じて load。
type EngineShard = {
  shardId: ShardId;
  rootThreadId: ThreadId;
  currentSnapshot: string;              // どの版の code か (migration の足場、Option A)

  // ── flat State から「per-shard」に移すもの ──
  threads: Record<ThreadId, Thread>;
  scopes: Record<ScopeId, Scope>;
  closures: Record<ClosureId, ClosureRecord>;   // shard-local に閉じる
  nextClosureId: number;
  pendingDelegateOut: Record<DelegationId, ThreadId>;  // shard 内の発行元 thread
  delegationSenders: Record<DelegationId, Endpoint>;   // ack 返送先
  escalationOwners: Record<EscalationId, ThreadId>;    // shard 内の handler thread
  nextScopeId: number; nextThreadId: number; nextCallId: number; nextAskId: number;
  lastGcScopeCount: number;
};

// project-local index = 常時 load の軽量テーブル。shard 本体は需要に応じて load。
// flat State の「routing 用 map」を shardId 解決に置換。
type ProjectIndex = {
  delegations: Record<DelegationId, ShardId>;        // inbound delegate の受け先 shard
  pendingDelegateOut: Record<DelegationId, ShardId>; // delegateAck/terminateAck の resolve 先
  escalationOwners: Record<EscalationId, ShardId>;   // escalateAck の resolve 先
};
```

**分割の原則**: flat State の `delegations` / `pendingDelegateOut` / `escalationOwners`
(現状 `→ ThreadId`) は **2 段**になる:

- **ProjectIndex** が `id → ShardId` (どの shard を load するか)
- **EngineShard** が `id → ThreadId` (load 後、shard 内の resolve)

closures は **shard-local** に閉じる (project index を軽量に保つ)。cross-shard closure call
は `ClosureRecord.originShardId` を辿って on-demand load (低頻度想定)。
→ `ClosureRecord` に `originShardId: ShardId` を追加。

## 3. event → 必要 shard の決定

原則: **その event を「待っている」thread が住む shard だけ load**。delegate のみ待ち手が
無い (新規起動) ので新 shard を作る。

| event | load する shard | 解決方法 |
| --- | --- | --- |
| `delegate` | 新規 shard (子 root) **のみ** | `shardId = 新 delegationId`。値は全部 payload、親は読まない |
| `delegateAck` | 発行元 shard | `ProjectIndex.pendingDelegateOut[delegationId]` |
| `terminate` | 受信側 shard (子 root) | `ProjectIndex.delegations[delegationId]` |
| `terminateAck` | 発行元 shard | `ProjectIndex.pendingDelegateOut[delegationId]` |
| `escalate` | 受信側 shard (親 = capability owner) | `ProjectIndex.escalationOwners` + 親 chain (§3.1) |
| `escalateAck` | 発行元 shard (子) | escalation を発行した shard (escalationId で逆引き) |

### 3.1 escalate routing の porting リスク (要注意)

`escalate` の受信側 shard 解決は唯一の非自明ケース。現 flat `applyEvent` は escalate を
handler thread に直接 route しているが、sharded では「どの shard に handler がいるか」を
先に引く必要がある。**`escalate` event 自体が `escalationId` を持ち、発行時に親の
`escalationOwners` index に `escalationId → ShardId` を登録**しておく (= delegate で子 shard
を作るとき、その親 shard id を子の `delegate` payload か delegation table 経由で知れる)。

→ **invariant test を必須にする** (§9): 「孫が祖先の capability に escalate → 正しい祖先
shard だけが load されて handle される」。ここは現 `applyEvent` の escalate 分岐を読みながら
慎重に port する。設計段階で完全に詰めず、test-first で固める領域として明示する。

## 4. storage 層 (Phase B schema を repo 化)

Phase B で **table は既に定義済み** (`engine_shards` / `project_index`、
[storage-schema-and-api §2](2026-05-30-storage-schema-and-api.md))。E では repo を実装し、
`CoreCheckpointStore` (snapshotId → flat checkpoint) を置換する。

```ts
// CoreCheckpointStore を置換する 2 つの store。両方 CoreTx 経由で同一 tx に参加。
interface ShardStore {
  get(projectId, shardId): Promise<EncryptedShard | null>;
  upsert(projectId, shardId, currentSnapshot, shard: EncryptedShard, status): Promise<void>;
  delete(projectId, shardId): Promise<void>;               // 完了 shard の即時 delete
  listActive(projectId): Promise<{ shardId, currentSnapshot }[]>;  // recovery 用
}
interface ProjectIndexStore {
  get(projectId): Promise<ProjectIndex | null>;
  upsert(projectId, index: ProjectIndex): Promise<void>;
}
```

- `engine_shards.payload` は `encryptCheckpoint(serialize(shard))` (既存 secret 暗号化を流用)
- `engine_shards.current_snapshot` は `ON DELETE RESTRICT` (走っている版の snapshot は消せない)
- shard serialize は **Phase A deliverable #5 の昇格** をここで発火: persist 時に閾値超の
  inline byte-sequence を `owner=core` ref に昇格 (`ValueStore.putComplete`)。これで CORE state
  が肥大しない。昇格は **persist 専用** (valueToRaw では昇格しない、[value-and-streaming §11](2026-05-30-value-and-streaming.md))
- `InMemoryStorage` 側にも対応する in-memory ShardStore/IndexStore を足す (test 用)

## 5. CoreModule の rewrite

```ts
// 現: snapshotId keyed, 1 flat State
// 新: projectId keyed, multi-snapshot IR registry + shard cache + project index
class CoreModule {
  constructor(opts: {
    projectId: string;
    snapshots: Map<SnapshotId, IRModule>;   // (snapshot, qname) → IR を引くための registry
    endpoint, logger,
  })

  // feed は既に async。中で:
  async feed(event):
    1. event の種類から必要 shardId を決定 (§3、ProjectIndex を引く)
    2. shard を load (cache miss なら ShardStore.get)、delegate なら新規 createShard
    3. shard.currentSnapshot から IRModule を選び、async applyEvent(shard, irModule, event, materializeCtx)
    4. dirty shard を mark
    5. outbound を返す

  // persist は dirty shard のみ書く + ProjectIndex を書く + 完了 shard を delete
  async persist(tx: CoreTx):
    for shard of dirtyShards: tx.shards.upsert(...) (昇格込み)
    tx.index.upsert(projectId, this.projectIndex)
    for shardId of completedShards: tx.shards.delete(projectId, shardId)

  // load は ProjectIndex のみ即 load。shard は feed が on-demand。
  async load(tx: CoreTx):
    this.projectIndex = await tx.index.get(projectId) ?? emptyIndex()
}
```

- **agent_def 解決**: `delegate` の `agentDefId` (qname または closure:N) を受信 CORE が自分の
  registry で decode。top-level qname は `snapshots.get(currentSnapshot)` の IR から block を引く。
  closure は shard-local closures から。**snapshot 軸**: 子 shard の `currentSnapshot` は親が
  delegate するとき payload に載せる (= `agentLiteral.snapshot`、§7)
- **shard lifecycle**: `delegate` で作成 → 完了 (root thread done) で `completedShards` に入れ
  persist で delete (replay 不要 → retention 不要)

## 6. async quantum (engine の async 化、D-async がここに乗る)

`applyEvent / drive / step` を `async` にする。ripple は **engine 内部 + CoreModule.feed
(既に async) + test/recovery 呼び出し元**に限定。

```ts
// 注入: shard load 後、CoreModule が ValueStore-backed の materialize ctx を渡す
type MaterializeCtx = {
  // ref → 完全 bytes。inline は即、ref は data-plane fetch を inline await (bounded I/O)
  materialize(rep: BytesRep): Promise<Uint8Array>;
};

async function applyEvent(shard, irModule, event, ctx): Promise<Result>   // ← async
async function drive(...): Promise<void>                                  // 内部 event loop も async
async function step(...): Promise<void>                                   // prim 評価で await ctx.materialize
```

- **fetch するのは content 変形 prim だけ** (`concat` / `format` / `to_string` / `from_string` /
  `json.*`)。`==` / `match` / `length` は §Phase-D-sync で hash/metadata 済み → fetch 不要
- prim 実装: 現 `inlineText(v)` (ref で throw) を、変形 prim では `await ctx.materialize(v.rep)`
  に置換。produce 側 (concat の結果が大きければ ref 昇格) は persist 時昇格に委ねる (= concat は
  inline 結果を返し、shard serialize が必要なら昇格) — quantum 内で新 ref を作らないので単純
- **determinism**: fetch は content hash の純粋関数。state 遷移は materialize 後は純粋
- **crash-safe**: persist は quantum 末尾のみ。fetch await 中の crash → 最後の checkpoint を
  reload して event 再処理 (quantum は atomic)
- v0.1.0 では ref は常に complete なので**跨 quantum の suspend は不要** (`valueReady` は v0.2)

## 7. agentLiteral.snapshot (Phase A deferred)

Phase A で `agentLiteral` は qname のみ。E で `snapshot` 軸を足す:

```ts
| { kind: "agentLiteral"; snapshot: string; qualifiedName: QualifiedName }
```

- code reference = `(snapshot, qname)`、data reference = `(module, id)` と対称
  ([storage-schema-and-api §3](2026-05-30-storage-schema-and-api.md))
- wire (`$agent`): `valueToRaw` が snapshot を載せる、`valueFromRaw` が読む (Phase A の codec を拡張)
- delegate 時、子 shard の `currentSnapshot` をこの snapshot から取る → multi-snapshot 起動の足場

## 8. ProjectActor host (Orchestrator.tick の置換)

```ts
// 現: Orchestrator.tick(snapshotId, event) を request 毎に呼ぶ (cold)
// 新: Map<projectId, ProjectActor> を warm 保持、event を inbox に enqueue
class ProjectActor {
  bus: ExternalEventBus;            // warm (per-tick で捨てない)
  modules: { core, api, ffi, env }; // warm
  private inbox: Queue<Input>;
  private running = false;

  enqueue(input): void              // 外部 (API request / sidecar msg / timer) → inbox
  private async loop():             // serial。1 input = 1 quantum chain
    while (inbox.nonEmpty):
      input = inbox.dequeue()
      try:
        各 module が自分の tx で load → feed/drain → persist → commit  (§6 of runtime-arch)
      catch: this.evict()           // tx 失敗 → actor を捨てる (次回 DB reload で整合回復)
}

class ProjectActorHost {
  private actors = new Map<projectId, ProjectActor>();
  route(projectId, input):          // actor を取得 (無ければ reactivate = DB から module 構築)
    this.getOrActivate(projectId).enqueue(input)
}
```

- **single activation**: project ごとに in-memory instance は 1 つ。serial loop で同 project の
  event は直列。並行性は project 間 (別 actor) で得る
- **`withSnapshotLock` 廃止**: actor が single-threaded なので DB lock 不要
- **tx は module の責務**: bus は tx を持たない。各 module の feed が自分の tx で
  load+persist+commit。cross-module atomicity は捨てる (delegation table が outbox/inbox)
- **bus は warm**: per-tick で作り捨てしない (durable object の event loop)。`bus.push(event)` で
  sidecar 等の async 結果を inject (既存機構)
- **api-server 側**: `orchestrator-adapter.ts` を ProjectActorHost への routing に書き換え。
  route handler は `host.route(projectId, input)` を呼ぶ。`TickModulesFactory` は
  「per-actor の module factory」に変わる (cold per-tick → warm per-actor)

## 9. crash recovery

```
crash → 再起動
  → project actor は遅延 reactivate (次 event で DB から module 構築)
  → ProjectIndex を load、active shard は listActive で把握 (本体は on-demand)
  → in-flight 再導出:
      - sidecar 応答待ち → 既存 recoverInflight (ipcDelegateRestarted)
      - cross-module in-flight → delegation table から re-drive (既存 recovery の一般化)
      - produce 途中 ref → errored 化 (Phase C/G)
  → loop 再開
```

DB が truth。in-memory (actor / shard cache / bus) が飛んでも最後の静止点から続く。
delegation table = de-facto transactional outbox/inbox、`delegationId`/`escalationId` で
idempotent dedup。

## 10. 段階導入 (de-risk のための sub-phase)

E は engine 全体に波及するため、**各 step を既存 e2e (22 sample) で regression 確認**しながら
進める。

| sub-phase | 内容 | 検証 | リスク |
| --- | --- | --- | --- |
| **E0: async engine** | `applyEvent/drive/step` を async 化 (動作不変、await を通すだけ) + D-async の `materialize` 注入 + 変形 prim の ref 対応 | 既存 e2e 全 green (挙動不変) + ref operand の concat/format test | 低 (機械的、module 境界は既に async) |
| **E1: shard 分割 (storage)** | flat State → `EngineShard`+`ProjectIndex`、ShardStore/IndexStore 実装、**既存 per-tick orchestrator のまま** projectId keyed で shard+index を load/persist | 既存 e2e 全 green (per-tick のまま sharded)、shard round-trip unit test | 中 (state 再構造化、routing) |
| **E2: actor host** | `Orchestrator.tick` → `ProjectActor` (warm serial loop)、`withSnapshotLock` 廃止、bus warm、orchestrator-adapter 書き換え | 既存 e2e 全 green、複数 project 並走 test | 高 (host 層 rewrite) |
| **E3: multi-snapshot + sidecar env** | `(snapshot,qname)→IR` registry、`agentLiteral.snapshot`、per-project FfiModule + sidecar env 配線 (C 残り) → **e2e `23-blob-echo`** | 23-blob-echo green (produce→ref→fetch round-trip)、複数 snapshot 起動 test | 中 |

**E0 を最初に**: async 化だけ先に landing させると、D-async (materialize) がここで完成し、
かつ sharding と分離して検証できる (挙動不変の機械的変更)。E1 以降の state 再構造化と
独立に de-risk できる。

## 11. invariants (test で固定する)

1. **shard 独立性**: ある shard の load/persist が他 shard の state を読まない (delegate quantum
   は子 root のみ load、親 shard 不要)
2. **escalate routing** (§3.1): 孫→祖先 capability の escalate が正しい祖先 shard だけを load
3. **closure cross-shard**: `originShardId` 経由の on-demand load で cross-shard closure call が動く
4. **完了 shard delete**: root done で shard が物理 delete され、再 load されない
5. **determinism**: 同じ blob store + 同じ event 列 → 同じ最終 state (fetch は純粋関数)
6. **crash atomicity**: quantum 途中 (fetch await 中) の crash → event 再処理で同一結果
7. **serial loop**: 同 project の並行 input が直列化 ([[project_orchestrator_txref_deadlock]]
   の deadlock を再発させない)
8. **昇格透過**: inline-only の値と persist 昇格された ref 値が観測等価 (==/match/length が同結果)

## 12. 影響ファイル (実装時の触る範囲)

- `engine/state.ts` → `EngineShard` / `ProjectIndex` 型 (flat State を分割)
- `engine/apply.ts` `engine/runner.ts` → async 化 (drive/step/applyEvent)
- `engine/prim.ts` → 変形 prim を `await ctx.materialize` に
- `engine/snapshot.ts` → shard serialize + persist 昇格 (ValueStore 注入)
- `modules/core.ts` → projectId keyed、multi-snapshot、shard load/persist、ProjectIndex
- `modules/ffi.ts` → per-project、sidecar env 配線 (C 残り)
- `orchestrator/*` → ProjectActor host (tick → actor)、`withSnapshotLock` 削除
- `api-server/orchestrator-adapter.ts` `routes/*` → ProjectActorHost routing
- `storage/` (api-server) → ShardStore / ProjectIndexStore (Postgres + memory)
- `value-codec.ts` → `agentLiteral.snapshot` の wire

## 13. open questions (実装着手時に決める)

1. **escalate の親 shard 解決** (§3.1): `escalationOwners` index への登録タイミングを
   delegate payload にするか delegation table 経由にするか — test-first で固める
2. **shard cache の eviction**: 1 quantum 内で load した shard を actor が warm に持つか、
   quantum 末で捨てるか。v0.1.0 は「quantum 内のみ warm、末で捨てる」で単純化 (memory 上限気にせず)。
   warm shard cache は v0.2 最適化
3. **persist 昇格の閾値**: inline → ref の byte 閾値 (例 4KB?)。小さい値は inline のまま
   (CORE state に乗せて良い、[[project_sample_writing_gaps]] の議論)。要 benchmark
4. **per-project module factory の DI**: 現 `TickModulesFactory` (per-tick) を per-actor factory に。
   storage tx の貼り方 (module 毎 tx) を adapter でどう表現するか
```

## 14. 改訂 (2026-05-30 後半): Module 自己完結モデル

設計議論の結果、host / bus / Module の責務を以下に確定した。E0/E1/E2-shard は landing 済み
(async engine / promotion / per-agent shard)。本節は **host 層 (E2 残り)** の最終形。

### 3 層の責務

- **Module** = 独立実体。katari-protocol (`feed` = 6 events) + **ドメイン機能 (file/run/...) を
  method として内包**。**自分で tx を張り、自分で直列化する**。warm (常駐)。root storage を保持し、
  feed / method 毎に tx を開く (= 1 quantum 1 tx、cross-module atomic は捨て delegation table で
  eventual consistency)。
- **bus** = pure router。`event.to` で `Module.feed` に dispatch するだけ。tx も lock も持たない。
- **host** = 各 Module の **薄い proxy**。やるのは「外部 trigger (HTTP / sidecar / timer) →
  該当 Module の method を叩く」+ bus を回すだけ。**tx も直列化も持たない**。

旧 `Orchestrator.tick` の「1 request = 1 tx + 1 snapshot lock で drain 全体を包む」は廃止
(= §1 で批判した癒着)。

### 直列化 = Module の責務 (host ではない)

host が proxy で直列化しないので、同 project の concurrent 入力 → concurrent feed になりうる。
**CORE は内部に per-project mutex** を持って自己直列化する (in-memory、single-process)。
per-shard 並行化 (v0.2) は **この mutex の粒度を per-shard に変える CORE 内部変更だけ** で済む
(host / bus 不変)。`withSnapshotLock` は廃止。

### Module 構成

- **CoreModule**: warm。`shardCache` + `projectIndex` を in-memory に warm 保持 + per-project
  mutex。`feed` は mutex → `storage.withTransaction` → (index で route → shard load →
  applyEvent → reconcile → dirty shard を promote+persist → completed を delete) → commit。
  crash で in-memory が飛んでも DB から reload。
- **ApiModule**: protocol `feed` (delegate/escalate) + **domain method** (`startRun` / `cancelRun`
  / `uploadFile` / `listFiles` / `deleteFile` / `answerEscalation` / `deploySnapshot` / `setEnv`
  / ...) を内包。各 method が自分の tx を張る。REST route は **proxy** (route → ApiModule method)。
- **FfiModule / EnvModule**: 同様に feed が自分の tx を張る。warm。

### host (ProjectActorHost)

```
ProjectActorHost
  - Map<projectId, ProjectActor>          (warm、遅延 reactivate)
  - ProjectActor = warm bus + warm 4 module (+ per-project mutex は CORE 内)
  - 外部 trigger → 該当 project の actor を取得 → Module method を proxy 呼び出し → bus drain
  - tx も lock も持たない (Module が各自で)
```

### Module interface の簡素化

`feed(event)` のみ (各自 tx)。旧 `load(tx)` / `persist(tx)` (host が tx を渡す) は廃止。warm な
Module は起動時/初回 feed で DB から自分の state を hydrate し、feed 毎に自分の tx で persist。
