# Runtime アーキテクチャ — durable object モデル

> [overview](2026-05-30-overview.md) の D12-D23 の詳細。
> engine の host 層を tick-based から actor-based に作り直す設計。

## 1. 現状モデルの診断

現状の `Orchestrator.tick` は 3 つの別概念を "tick" に癒着させている:

| 概念              | 本来の寿命              | 現状                    |
| ----------------- | ----------------------- | ----------------------- |
| router (bus)      | 永続でいい (state なし)  | tick 毎に作って捨てる    |
| module state      | warm に保ちたい          | tick 毎に DB から reload |
| transaction 境界   | event 量子ごと          | tick = transaction      |

stream 完了の再 trigger が困難なのはこの癒着が原因。 async 完了が来たとき元の bus は
もう無く、 新 tick で cold module を作り直すしかない。

## 2. project runtime = durable object (D12)

project runtime を 1 つの **durable object** (Orleans grain / Akka cluster sharding /
Cloudflare Durable Objects と同じパターン) と見なす:

- **単一 activation** (= project ごとに in-memory instance は 1 つ)
- **serial event loop** (= 同 project 内の event は直列処理)
- **state は DB backing** (= crash 復旧用)
- **idle で evict、 次 event で reactivate** (= reload from DB)

v0.1.0 は単一 process で全 project を warm に持つ。 eviction (LRU) と multi-server
の project affinity は v0.2+。

## 3. bus = 6 events の pure router (D13)

bus は routing のみ。 state も transaction も持たない。

- 6 events: `delegate` / `delegateAck` / `terminate` / `terminateAck` / `escalate` / `escalateAck`
- self-addressed (CORE→CORE) も特別扱いせず loop back
- `bus.push(event)` で module が async 結果を inject できる (= 既存機構)
- bus は idle になるが **死なない** (= durable object の event loop)

## 4. Module object (永続) と Module state (DB SSoT) の分離 (D14)

| 層                        | SSoT      | 寿命                  | 中身                                          |
| ------------------------- | --------- | --------------------- | --------------------------------------------- |
| **Module object**         | in-memory | 永続 (process 生存中)  | routing identity、 SSE subscription、 sidecar handle |
| **Module state (engine)** | **DB**    | quantum 毎 load/persist | shards、 scopes、 threads、 delegation index    |

Module object は常に in-memory にいる (= bus の routing 先)。 engine state は DB が真で、
event を見て必要 shard を load、 処理後 persist する。 chunk buffer などの ephemeral な
in-memory は Module object 側 (= crash で消えて良いもの)、 durable な state は DB。

## 5. feed = 1 quantum (D15, D16)

`feed` は async。 1 回 = 1 quantum:

```
feed(event):                          ← async
  1. event を見る
  2. load すべき shard を決定 → DB から load (await)
  3. engine を実行 (state を mutate)
       - prim が ref の bytes を要するとき (concat / format / substring 等) は
         content-addressed fetch を inline await する  ← bounded I/O
  4. dirty shard を DB に persist (await)
  5. outbound (= 6 events のどれか) を返す
```

engine は **deterministic だが async** (= host の content-addressed fetch を await する)。
重要な性質は保たれる:

- **deterministic**: fetch は content hash の純粋関数 (= 同じ blob store なら同じ結果)。
  state 遷移ロジックは materialize された値が決まれば純粋
- **crash-safe**: persist は quantum 末尾のみ。 fetch await 中に crash → 最後の checkpoint を
  reload して event を再処理 (= quantum は atomic)

fetch するのは content を**変形する** prim (concat / format / substring) だけ。 `==` /
match / `length` は ref の hash / metadata で済むので **fetch 不要**
([value-and-streaming §2](2026-05-30-value-and-streaming.md))。

await の種類:

- **v0.1.0: bounded fetch (complete blob)** → quantum 内で inline await (= ms、 actor が
  少し止まるだけ、 project 内 serial で問題なし)
- **v0.2: 無期限待ち (building stream の完了)** → inline await すると actor が分単位で固まる
  ので、 thread を suspend して feed 早期 return → 完了で resume quantum
  ([v0.2-streaming](2026-05-30-v0.2-streaming.md))

## 6. transaction は module の責務、 cross-module atomic は捨てる (D17, D18)

bus は tx を持たない。 各 module が自分の feed (= 1 quantum) で tx を開いて
load + persist + commit する。

帰結: **cross-module atomicity は無い**。 API→CORE→FFI の連鎖は各 hop が別 tx。
これは分散システムとして正しい (= bus を跨ぐ 2PC は scale しない・不要)。 各 module が
自分の consistency boundary、 bus event は eventual-consistency の message。

### 信頼性 = 6-event protocol + delegation table (outbox/inbox) + recovery

crash 時に「API は commit、 CORE 未処理、 in-flight bus event 消失」 が起こりうる。
これを救うのは **既存の delegation tracking table**:

- 各 module が「未完の cross-module 操作」 を自分の tx 内で durable に記録
  (CORE の `pendingDelegateOut`、 FFI の `ffi_pending_*` 等)
- crash 復旧時、 各 module が outstanding operation を見て re-drive
- `delegationId` / `escalationId` で idempotent に dedup

つまり delegation table が de-facto な transactional outbox/inbox。 これは現状の
`recoverInflight` の一般化。 bus 自体は in-memory best-effort で良い (= 消えても
recovery が拾う)。

## 7. engine-internal event は bus に出さない (D19)

event.ts は既に 2 層:

- external events (6 つ): bus を流れる
- internal events (create / done / cancel / ask / askAck): engine 内部 queue のみ

v0.1.0 では値が常に complete で、 必要な fetch は **bounded** なので quantum 内で inline
await する (§5)。 thread を suspend して跨 quantum で resume する新 internal event
(`valueReady`) は **不要**。 v0.2 で observable streaming を入れると、 building ref の
**無期限**完了待ちで thread を suspend する必要が出るので、 そこで `valueReady` を
engine-internal event として追加する ([v0.2-streaming](2026-05-30-v0.2-streaming.md))。
bus には出さない。

quantum は「load → 実行 (bounded fetch を inline await) → persist」 の形。 v0.1.0 では
trigger は bus event (feed) のみ。 v0.2 で無期限待ちの resume quantum が加わる。

## 8. data plane: 中央 broker を作らない (D20, D21)

> v0.1.0 では値は常に complete blob。 中央 broker object は作らず、 data plane は
> **complete blob の produce + fetch** に絞る。 mid-stream subscribe / building state /
> SSE await / engine-internal valueReady は [v0.2-streaming](2026-05-30-v0.2-streaming.md)。

v0.1.0 の data plane (HTTP):

- **produce** (module-internal): owning module が complete blob を作って value store に書く。
  FFI sidecar (別 process) は HTTP で `PUT chunk` → `POST close` (= 累積して complete に)、
  CORE/API/ENV は in-process で直接 storage 書き込み
- **consume** (cross-module read-only): `GET /value/:module/ref/:id` (= 全 bytes)、
  `?range=N-M` (= 大 file の部分 fetch)。 complete blob のみ

CORE が ref の bytes を要する content 変形 prim (concat / format / substring) は complete
blob を **bounded fetch** する (= quantum 内で inline await、 §5)。 == / match / length は
hash / metadata で済み fetch しない。 v0.1.0 の cancel は通常の terminate cascade のみ
(= producer は delegation 内で完結、 detach しない)。 producer の中途 cancel や mid-stream
subscribe を要する非同期 streaming は v0.2。

### process 境界

v0.1.0 で別 process は **sidecar のみ**。 host process 内に bus / CORE / FFI / API / ENV /
data-plane HTTP server / storage が全部いる。

- **sidecar** (別 process): produce / consume とも HTTP data-plane 必須
- **host 内 module**: consume は data-plane API 経由 (uniform、 multi-server 視野)、
  produce は owning module の storage 書き込み (module-internal)

## 9. per-agent shard (D22, D23)

### Shard 定義

```ts
type ShardId = string;  // = top-level (root) delegation id = instance id

type EngineShard = {
  shardId: ShardId;
  rootThreadId: ThreadId;
  currentSnapshot: string;          // Option A: どの版の code か (migration の足場)
  threads: Record<ThreadId, Thread>;
  scopes: Record<ScopeId, Scope>;
  closures: Record<ClosureId, ClosureRecord>;   // shard-local (closures を shard に閉じる)
  nextClosureId: number;
  pendingDelegateOut: Record<DelegationId, ThreadId>;
  delegationSenders: Record<DelegationId, Endpoint>;
  escalationOwners: Record<EscalationId, ThreadId>;
  nextScopeId: number; nextThreadId: number; nextCallId: number; nextAskId: number;
  lastGcScopeCount: number;
};

// project-local index (= 常時 load、 軽量。 shard 本体は需要に応じて load)
type ProjectIndex = {
  delegations: Record<DelegationId, ShardId>;        // inbound delegate の受け先
  pendingDelegateOut: Record<DelegationId, ShardId>; // delegateAck/terminateAck の resolve
  escalationOwners: Record<EscalationId, ShardId>;   // escalateAck の resolve
};
```

closures は shard-local に閉じる (= project index を軽量に保つ)。 cross-shard closure
call は ClosureRecord の `originShardId` を辿って on-demand load (= 頻度は低い想定)。

### event → 必要 shard の決定

原則: **その event を「待っている」 thread が住む shard だけを load**。 delegate のみ
「待っている thread」 が無い (= 新規起動) ので新 shard を作る。

| event        | load する shard                                  |
| ------------ | ------------------------------------------------ |
| delegate     | 新規 shard (= 子 root) **のみ** (値は全部 payload に乗る、 親は読まない) |
| delegateAck  | 発行元 shard (= `pendingDelegateOut[delegationId]`) |
| terminate    | 受信側 shard (= `delegations[delegationId]`、 子 root) |
| terminateAck | 発行元 shard (= `pendingDelegateOut[delegationId]`、 terminate を発行した DelegateThread が住む shard) |
| escalate     | 受信側 shard (= 親、 escalation owner index)       |
| escalateAck  | 発行元 shard (= 子)                               |

delegate の発行 (= 親の DelegateThread が outbound delegate を出す) と受信 (= 子 root を
起動) は別 quantum。 受信 quantum では子 root だけ load すればよい (= 親 shard は不要)。
ack 系は delegationId / escalationId しか持たないので、 `delegationId → shardId` の
project-local index が「snapshot を知らずに」 引ける必要がある (= project スコープの軽量 index)。

### load と lock を分ける (D23)

- **load 粒度 = shard** (= touched shard のみ load): memory / IO の勝ち。 これが目的
- **lock 粒度 = project の serial event loop**: durable object が single-threaded なので
  DB lock 不要。 並行性は project 間 (= 別 actor) で得る

v0.1.0 は「per-shard load + per-project serial loop」。 per-shard 並行は v0.2 課題
([[project_orchestrator_txref_deadlock]] の教訓から lock は保守的に)。

## 10. crash 復旧

```
crash
  → 再起動: project actor を必要に応じて reactivate
  → DB から最後の checkpoint を reload (= 静止点の state)
  → in-flight 再導出:
      - sidecar 応答待ち → recoverInflight (= ipcDelegateRestarted)
      - cross-module in-flight → delegation table から re-drive
      - (v0.2) suspended thread の building ref を走査して await 再接続
  → loop 再開
```

DB が truth なので in-memory が飛んでも最後の静止点から続く。

## 11. 既存 orchestrator への影響

```
現状: tick = tx + snapshot lock + build modules + drain + persist
  ↓
新: ProjectActor host
  - Map<projectId, ProjectActor> を in-memory 保持
  - 各 ProjectActor = bus + 4 module + data-plane server (warm)
  - 外部 input (API request / sidecar message / timer):
      → 該当 project actor の inbox に enqueue
      → actor の serial loop が処理
      → 各 module が自分の tx で load + persist + commit
  - withSnapshotLock は不要 (= actor が single-threaded)
  - tx 失敗時は actor を evict (= 次回 DB reload で整合回復)
```

これは現状コードからの大 refactor。 Phase E (per-agent shard) と統合して実施する。
