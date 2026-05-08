# Phase 1: 全体設計の評価

## 1. ライブラリ単位の責務 (大きな設計)

### 1.1 katari-runtime

**位置づけ**: Katari IR (JSON) を解釈実行する `pure / non-IO` な state machine + facade。

**公開 API ([src/index.ts](../typescript/packages/katari-runtime/src/index.ts))**:
- 関数: `createMachine`, `applyEvent`, `processQueue`, `collectGarbage`, `serializeMachine`, `deserializeMachine`, `serializeScope`, `deserializeScope`, `buildConsoleLogger`, `consoleLogger`, `noopLogger`
- クラス: `MachineHandle`, `Thread`, `ChildThread`, `APIThread`, `UserThread`, `PrimThread`, `RequestThread`, `ExternalThread`, `CtorThread`, `MatchThread`, `ForThread`, `HandleThread`, `TupleThread`, `ArrayThread`
- 型: `MachineState`, `Scope`, `Value`, `MachineEvent`, `MachineEventPayload`, `ThreadId`, `ScopeId`, `DelegationId`, `EscalationId`, `CallId`, `Boundaries`, `BoundaryKey`, `Endpoint`, `IRModule`, `BlockId`, `QualifiedName`, `SchemaBundle`, `AgentDefinition`, `JsonSchema`, `Logger`, `LogLevel`, `MachineSnapshot`, `SerializedThread`, `SerializedScope`, `RecoverableEngineError`, `EntryNotFoundError`, `IrrecoverableEngineError`

**評価**: 公開 API が **広すぎる**。`Thread` サブクラス (11 個) や `SerializedXxxThread` の派生型は内部実装の詳細であり、本来は隠蔽されるべき。

### 1.2 katari-api-server

**位置づけ**: HTTP layer + 永続化 + machine ライフサイクル管理。

**公開 API ([src/index.ts](../typescript/packages/katari-api-server/src/index.ts))**:
- `buildApp`, `MachineRegistry`, `AgentService`, `ModuleService`, `recoverOnBoot`, `InMemoryStorage`, `PostgresStorage`
- 例外型: `MachineNotFound`, `AgentNotFound`, `EntryNotFoundError`, `ModuleNotFound`, `AgentDefinitionNotFound`
- 型: `AgentId`, `AgentRow`, `AgentState`, `ModuleRow`, `ModuleSummary`, `Storage`, `VersionId`

**評価**: ほぼテスト用途。production の entry は `bin.ts`。これは妥当な分離。

### 1.3 ライブラリ間の依存関係

```
katari-api-server  ──depends on──▶  katari-runtime (workspace:*)
                                          │
katari-runtime  ──exports──▶  IR types / Value / MachineHandle / ...
                                          │
                                          └─── 内部で循環: machine/ ↔ runtime/
```

**問題**: `katari-runtime/src/machine/` 内のいくつかのファイルが `katari-runtime/src/runtime/errors.ts` および `runtime/logger.ts` を import している:

| 場所 | 何を import しているか |
|---|---|
| [machine/machine.ts:3](../typescript/packages/katari-runtime/src/machine/machine.ts#L3) | `noopLogger`, `Logger` from `runtime/logger` |
| [machine/thread/api.ts:7](../typescript/packages/katari-runtime/src/machine/thread/api.ts#L7) | `EntryNotFoundError` from `runtime/errors` |
| [machine/thread/user.ts:5](../typescript/packages/katari-runtime/src/machine/thread/user.ts#L5) | `RecoverableEngineError` from `runtime/errors` |
| [machine/thread/match.ts:5](../typescript/packages/katari-runtime/src/machine/thread/match.ts#L5) | `RecoverableEngineError` |
| [machine/thread/prim.ts:4](../typescript/packages/katari-runtime/src/machine/thread/prim.ts#L4) | `RecoverableEngineError` |

設計コメント (snapshot.ts:3-7) では「runtime/ は machine/ のファサード」と謳っているが、実装は **machine/ → runtime/** という逆参照を含む。これは明確な層違反。

**根本原因**: エラー型と Logger を「ホスト境界用」に抽象化しているが、それを machine/ 内で直接使ってしまっているため。`pure engine layer` という思想に反している。

## 2. ライブラリ内部の責務 (小さな設計)

### 2.1 katari-runtime の構造

```
ir/                  IR types (Haskell mirror)
  types.ts           Block, Statement, Pattern, ...
  schema.ts          SchemaBundle (AI tool calling)

machine/             core state machine (purest layer)
  machine.ts         MachineState 型 + applyEvent + GC trigger
  runner.ts          processQueue メインループ + spawnChild factory
  events.ts          MachineEvent (CORE 境界)
  id.ts              ThreadId / ScopeId / DelegationId / EscalationId / AskId
  scope.ts           Scope, get/set, serialize, GC
  value.ts           Value 型, literalToValue, NULL_VALUE
  pattern.ts         tryMatch (UserThread/MatchThread 共通)

  thread/            Thread 階層
    types.ts         Thread / ChildThread base, Boundaries, QueueEvent
    index.ts         re-export
    api.ts           APIThread (root)
    user.ts          UserThread (BlockUser)
    prim.ts          PrimThread + executePrim + valueEquals
    ctor.ts          CtorThread
    external.ts      ExternalThread (FFI)
    match.ts         MatchThread
    for.ts           ForThread
    handle.ts        HandleThread (algebraic effect)
    tuple.ts         TupleThread
    array.ts         ArrayThread
    request.ts       RequestThread

runtime/             facade / I/O 寄りの薄いラッパ
  facade.ts          MachineHandle (startAgent / cancelAgent / feedEvent / toSnapshot)
  snapshot.ts        serialize/deserialize machine
  errors.ts          Recoverable / Irrecoverable / EntryNotFoundError
  logger.ts          Logger interface + console / noop adapters
```

**評価**:

#### 良い点

- `ir/` は Haskell IR の単純な型 mirror で I/O も依存関係も無く綺麗。
- `Thread` 階層は template method パターン (`onChildDoneFromRunner` 等の base 実装 + `onChildDone` 等の variant hook) で一貫しており、`runner.ts` 側に kind-switch が IR factory を除き残っていない。
- `boundaries` を slot 化して `exitKindReturn: UserThread | null` などに narrow してあるため、コンパイル時に「return は agent UserThread しか受けない」が保証されている。
- `handlers: ReadonlyMap<ReqId, HandleThread>` (HandleThread に narrow) も同様に型レベル安全。
- `pattern.ts` の `tryMatch` を MatchThread と UserThread 両方で共有しているのは適切。
- `value.ts` の `NULL_VALUE` を frozen singleton にしているのは良いキャレフル。

#### 問題点 (small design)

1. **TupleThread と ArrayThread のコード重複** ([tuple.ts](../typescript/packages/katari-runtime/src/machine/thread/tuple.ts), [array.ts](../typescript/packages/katari-runtime/src/machine/thread/array.ts)): 構造的にほぼ同じ (`collected: Map`, `nextIndex`, sequential/parallel 分岐, `emitDone` で配列に詰める)。差は最終 Value の `kind: "tuple" | "array"` のみ。共通基底クラス `CollectingChildThread<K extends "tuple" | "array">` で抽出可能。

2. **Snapshot serialize / deserialize の boilerplate**: 11 thread 全てに `serialize()`, `restoreSkeleton()`, `link()` の 3 メソッド + 専用 type が必要。`InternalMutable<T>` cast が頻発し、unsafe な type-cast が散在。**Mixin / Decorator** または **type-driven serialization** に振れる余地あり。

3. **`MachineState.lastGcScopeCount` のドキュメント**: GC 抑制ロジックが `applyEvent` の末尾だけで動くが、複数の applyEvent が連続で来た時の挙動が暗黙。

4. **`MachineState.pendingOutEvents` の transient 化**: コメントで "transient" と注釈しているが、ESM module で thread コードから直接 push する設計。スレッド関数群が引数で渡されないストレージにアクセスするのは隠れた依存。

5. **`createScopeId` などの ID 生成が `crypto.randomUUID()` 固定**: テストで決定的にしたい時に困る。dependency injection できない。

6. **`Logger` がインターフェースとして抽象化されているのに、`MachineState` に直接持たせている**: テストでロガーを差し替えたい時に machine 全体を作り直す必要がある (実際は OK だが、event ごとに inject も可能だった)。

7. **Pattern bind 失敗時の throw が plain `Error`** ([user.ts:142](../typescript/packages/katari-runtime/src/machine/thread/user.ts#L142)): refutable pattern が降ってきた時に `Error` で throw すると **api-server は version を poison** する。コンパイラバグ由来であっても、**1 つの agent の問題で全 agent が死ぬ** のは過剰。

### 2.2 katari-api-server の構造

```
bin.ts                 process entry / wiring
index.ts               public API (テスト用)
metrics.ts             Counter / Gauge / Histogram + AppMetrics
recovery.ts            recoverOnBoot
registry.ts            MachineRegistry (LRU + Mutex + inFlight collapse)

routes/
  app.ts               Hono root + body limit + onError + auth/rate-limit wiring
  agent.ts             POST/GET/cancel agent
  agent-definition.ts  GET agent-definition (AI tool calling)
  module.ts            POST/GET module (upload / metadata)

  middleware/
    auth.ts            Bearer auth + constant-time compare
    rate-limit.ts      Per-IP token bucket
    validation.ts      Zod schemas

services/
  agent-service.ts     start / cancel / query / routeOutbound / poison / rollback
  module-service.ts    upload / list / get / agent definition

storage/
  types.ts             Storage / ModuleRepo / AgentRepo / SnapshotRepo interfaces
  pg.ts                Postgres impl
  memory-storage.ts    InMemory impl (test only)
  schema.sql           DB schema
```

**評価**:

#### 良い点

- 4 層 (HTTP / Service / Storage / Registry) で責任分離は明確。
- `Storage` interface により Pg / InMemory を差し替え可能。
- per-version `Mutex` により同一 version の applyEvent を直列化、`inFlight` Map で同時 acquire を deduplicate。
- `withTransaction` を `Storage` API として持つことで、agent 挿入と snapshot upsert の atomicity を確保。
- Zod schema によるリクエスト検証 + onError ハンドラで JSON parse / validation 失敗を 400 に変換。
- Auth / Rate limit が中間層で分離。

#### 問題点 (small design)

1. **`AgentService` (402 行) の責務肥大**: start, cancel, query, routeOutbound, versionedRollback, rebuildAndCache, poison が 1 クラス。
   - 抽出候補: `OutboundEventDispatcher` (routeOutbound 部), `MachineRebuilder` (versionedRollback / rebuildAndCache 部), `PoisonHandler` (poison 部)。

2. **`MachineRegistry` の二重責務**: cache (LRU) と mutex provider と replaceHandle (rollback 用)。`replaceHandle` は agent-service の都合で生やしただけのメソッド (registry 自体の本質ではない)。

3. **`Storage` インターフェースの粒度**: `withTransaction` がトップレベル、3 つの sub-repo はメンバー。多 backend 化を考えると、各 repo が個別の transaction を持つ formulation の方が拡張性が高い (が、現状 1 backend だけなら過剰設計)。

4. **`recovery.ts` が `services/` を参照**: 階層的には recovery は services と同レベルで OK だが、agentService が optional 引数で渡される設計は中途半端。

5. **`bin.ts` が DI コンテナ的役割を担っているが手書き**: 依存先が増えると wiring が煩雑になる。

6. **`metrics.ts` が `AppMetrics` 型を export しているが routing path で 1 箇所しか読まれない**: `agent-service` での `applyEventDuration.observe` などはまだ実装されていない (export されているが unused)。

## 3. 抽象化の縦横整理

### 縦の層 (依存方向)

```
1. ir/ (型のみ)
   ↓
2. machine/ (pure engine)        ← 現状 logger/errors にも依存しているのが問題
   ↓
3. runtime/ (facade + serialize + errors + logger)
   ↓
4. api-server/storage/ (persistence)
   ↓
5. api-server/services/ (orchestration)
   ↓
6. api-server/routes/ (HTTP)
   ↓
7. api-server/bin.ts (wiring)
```

理想的には各層は **下位にしか依存しない** べきだが、`machine/ → runtime/` 逆参照が存在する。

### 横の単位 (機能 = vertical slice)

| 機能 | runtime | api-server |
|---|---|---|
| Thread / Block dispatch | machine/thread/* | n/a |
| Cancel | machine: boundaries, finishCancelling | services: cancelAgent |
| Effect (handle/req) | machine: HandleThread/RequestThread | n/a |
| FFI | machine: ExternalThread | services: routeOutbound (future) |
| Snapshot | runtime/snapshot.ts | storage: SnapshotRepo |
| Logging | runtime/logger.ts | bin.ts buildConsoleLogger |
| Metrics | n/a | metrics.ts |
| Recovery | n/a | recovery.ts |

機能ごとにファイルが点在しているが概ね妥当。FFI 周りの責任分担が未確定 (engine が emit するだけで dispatch は外) なのが浮いている。

## 4. 設計レベルの根本的な疑問

### 4.1 機構が複雑な所と単純な所の落差

- **複雑な所**: HandleThread (579 行)、ForThread (378 行)、UserThread (365 行)、Thread (786 行)、prim.ts (304 行)、agent-service.ts (402 行)、storage/pg.ts (344 行)。
- **単純な所**: PrimThread のクラス定義 (75 行)、CtorThread (74 行)、MatchThread (126 行)。

HandleThread の 579 行は実装の本質 (sequential queue + post-cancel actions + 3 種の child role) を考えればやむを得ないが、Thread base class の 786 行は **共通化のためのコード + snapshot boilerplate** がほとんど。

### 4.2 状態の所在

- `MachineState`: thread / scope / delegation map + queue + pendingOutEvents + logger + lastGcScopeCount
- 各 Thread: id, scopeId, parent, parentCallId, handlers, children, status, boundaries, pendingReturn + variant 固有
- HandleThread: childRoles, pendingActions, postCancelActions, nextCallId
- ForThread: currentIndex, postCancelActions, iterableSnapshot

各 Thread が自前の状態を持つのは OOP 的に自然だが、**snapshot のために全状態を JSON serializable に保つ制約** が個々の Thread のコードに散らばっている。

### 4.3 永続化単位

- **単位**: `versionId` (= module version)。1 version 内の全 agent が同じ engine を共有 (closure scope を共有するため)。
- **タイミング**: `applyEvent` の終わりに毎回 `snapshots.upsert`。
- **問題点**:
  - 1 version あたりの agent 数が増えると snapshot サイズが線形増加。
  - 全 agent が同じ snapshot に同居するため、頻繁な applyEvent で I/O 負荷が大きい。
  - **incremental snapshot / event sourcing** に振らない理由は文書化されていない。

### 4.4 Machine と FFI の境界

- 現状: ExternalThread が CORE→FFI delegate を `pendingOutEvents` に push、AgentService.routeOutbound が拾って **何もしない (`TODO(katari/ffi)` でログだけ)**。
- 結果: FFI を使う agent は `running` のまま永遠に放置される。
- 設計上の問題: FFI executor が無いまま production 設計を進めると、いざ FFI を実装するときに "registry / agentService に新しい状態を入れる必要がある" と判明し、層を破壊することになる。

## 5. Phase 1 結論

| 評価軸 | スコア (◎/○/△/×) | コメント |
|---|---|---|
| 大きな設計 (ライブラリ分け) | ○ | runtime / api-server の分離は妥当。再設計するなら api-server を更に細分化検討。 |
| 小さな設計 (モジュール分け) | △ | machine/ ↔ runtime/ 循環依存、AgentService 肥大、TupleThread/ArrayThread 重複。 |
| 抽象化の方向性 | ○ | Thread template method、Boundaries narrow、handlers narrow は秀逸。 |
| 公開 API 設計 | △ | runtime の re-export 過剰。Thread サブクラスを外に出している。 |
| 永続化の整合性 | ○ | per-version mutex + tx の組合せは堅牢。但し snapshot 一括書き換えは将来スケール限界。 |
| FFI 設計 | × | 未実装でかつ "外で誰かやってください" モード。本番運用には致命的。 |
| Recovery 設計 | △ | 機構は揃うが cancelling agent の resume が実装されていない (Phase 2 詳細)。 |

**全体評価**: 中核 state machine の設計は緻密で良くできている。一方で外側の I/O 層は責務が肥大気味で、API server の "未実装 / TODO" 部分 (FFI) と "潜在バグ" (recovery, rollback race, nested tx) が運用上のリスクとして残っている。
