# Phase 3: リファクタリング・バグ修正・実装計画

前提:
- リファクタリング時間は無限。
- プロジェクトは非公開段階。最小変更・後方互換・マイグレーションは一切考慮不要。
- "1 から作り直す前提"。

本計画は **再設計後の理想形** を最初に提示し、その後 **項目ごとの実装プラン** に落とす。

---

## 1. 再設計後の理想構造

```
typescript/packages/

  katari-ir/                                    [NEW] 純粋型のみのパッケージ
    src/
      types.ts                                  IR 型 (現 katari-runtime/ir/types.ts)
      schema.ts                                 SchemaBundle 型
      identifiers.ts                            BlockId / VarId / ReqId / CtorId / QualifiedName

  katari-engine/                                [RENAME from katari-runtime/machine] 純 pure engine
    src/
      machine.ts                                MachineState + applyEvent
      runner.ts                                 processQueue + spawnChild factory
      events.ts                                 MachineEvent
      id.ts                                     ThreadId / ScopeId / ...
      scope.ts                                  Scope + GC
      value.ts                                  Value
      pattern.ts                                tryMatch
      errors.ts                                 EngineError 階層 (engine 内に閉じる)
      thread/
        types.ts                                Thread / ChildThread / ...
        api.ts user.ts ...
    package.json                                依存: katari-ir のみ。logger 依存なし。

  katari-runtime/                               薄いファサード
    src/
      handle.ts                                 MachineHandle (renamed from facade.ts)
      snapshot.ts                               serialize/deserialize
      logger.ts                                 Logger interface + adapters
      errors-host.ts                            host-side error classification (Recoverable / Irrecoverable)
      outbound-router.ts                        [NEW] outbound event を抽象 EventSink へ振り分ける
    package.json                                依存: katari-ir, katari-engine

  katari-host/                                  [NEW] api-server から汎用 host 層を切り出し
    src/
      registry.ts                               MachineCache (LRU) — mutex は別
      version-mutex.ts                          [NEW] PerVersionMutex
      machine-rebuilder.ts                      [NEW] versionedRollback / rebuildAndCache
      event-sink.ts                             [NEW] CORE→FFI / CORE→API の dispatcher
      ffi-executor.ts                           [NEW] FFI 実行サブモジュール (HTTP / inproc)
      ffi-timeout.ts                            [NEW] external delegate のタイムアウト管理
      poison-handler.ts                         [NEW] AgentService.poison 切り出し
    package.json                                依存: katari-runtime, katari-engine

  katari-storage/                               [NEW] 永続化 abstraction
    src/
      types.ts                                  Storage / ModuleRepo / AgentRepo / SnapshotRepo
      memory.ts                                 InMemoryStorage
      pg.ts                                     PostgresStorage
      schema.sql

  katari-api-server/                            HTTP layer のみに痩せる
    src/
      bin.ts                                    process entry / DI wiring
      app.ts                                    Hono root
      services/
        agent-service.ts                        startAgent / cancelAgent / queryAgent (痩せる)
        module-service.ts                       upload / list / get
      routes/
        agent.ts agent-definition.ts module.ts
      middleware/
        auth.ts rate-limit.ts validation.ts
      metrics.ts
      recovery.ts                               cancelling resume を含む完全実装
```

### 1.1 パッケージ依存グラフ

```
katari-ir                                           (型のみ)
  ↑
katari-engine                                       (pure state machine)
  ↑
katari-runtime                                      (facade + snapshot + logger)
  ↑               ↗                  ↖
katari-host       katari-storage         (横並び: host が storage に依存)
  ↑                                       ↑
katari-api-server (HTTP layer)
```

### 1.2 公開 API の絞り込み

**katari-runtime** (外向け):
- `MachineHandle` (class), `serializeMachine`, `deserializeMachine`, `MachineSnapshot`, `Logger`, `LogLevel`, `RecoverableEngineError`, `IrrecoverableEngineError`, `EntryNotFoundError`
- 型: `IRModule`, `Value`, `MachineEvent`, `DelegationId`, `ThreadId` 等の id types

**Thread サブクラスは export しない**。internal use only。
**`MachineState`, `Scope`, `Boundaries` 等のエンジン内部型も export しない**。

---

## 2. 修正・実装項目 (粒度別)

### 2.1 Critical bug fixes (即実装)

#### [BUG-01] Recovery の cancelling agent resume

**現状**: [recovery.ts:94](../typescript/packages/katari-api-server/src/recovery.ts#L94) が `agents.cancelAgent(row.id)` を呼ぶが、`cancelAgent` 内の `setState(..., expectedState: "running")` が `cancelling` に対しては不一致で no-op。

**修正案**:
1. `AgentService` に `resumeCancellingOnBoot(agentId, versionId)` 専用メソッドを追加。
2. このメソッドは:
   - `expectedState` 検査をスキップ
   - 直接 `handle.cancelAgent(delegationId)` を呼んで engine に terminate を送る
   - outbound event (terminateAck) を `routeOutbound` に流す
   - snapshot を upsert
3. `recovery.ts` はこの新 API を呼ぶ。

```ts
// agent-service.ts (after refactor)
async resumeCancellingOnBoot(agentId: AgentId): Promise<void> {
  const row = await this.storage.agents.get(agentId);
  if (row === null || row.state !== "cancelling") return;
  const handle = await this.registry.acquire(row.versionId);
  const mutex = this.registry.getMutex(row.versionId);
  await mutex.runExclusive(async () => {
    const rollbackSnap = handle.toSnapshot();
    try {
      await this.storage.withTransaction(async (tx) => {
        const out = handle.cancelAgent(row.delegationId);
        await this.routeOutbound(out, row.versionId, tx);
        await tx.snapshots.upsert(row.versionId, handle.toSnapshot());
      });
    } catch (err) {
      // rollback / poison ... (既存 path 流用)
    }
  });
}
```

#### [BUG-02] versionedRollback の fire-and-forget

**修正**: [agent-service.ts:330](../typescript/packages/katari-api-server/src/services/agent-service.ts#L330) を `void ... .catch(...)` から **同期 await に変更**。

```ts
private async versionedRollback(versionId: VersionId, snap: MachineSnapshot): Promise<void> {
  try {
    await this.rebuildAndCache(versionId, snap);
  } catch (err) {
    this.logger.log("error", ...);
    this.registry.evict(versionId);
  }
}
```

呼び出し元 (`startAgent` / `cancelAgent` の catch 節) は `await this.versionedRollback(...)` する。

#### [BUG-03] Postgres nested withTransaction

**修正**: [pg.ts:321-339](../typescript/packages/katari-api-server/src/storage/pg.ts#L321) の `withTransaction` 実装を内側 `txSql` を bind する形に変更。

```ts
async withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T> {
  return this.sql.begin(async (txSql) => {
    return runInTx(txSql as any, fn);
  }) as T;
}

function runInTx<T>(txSql: Sql, fn: (tx: Storage) => Promise<T>): Promise<T> {
  const txStorage: Storage = {
    modules: new PgModuleRepo(txSql),
    agents: new PgAgentRepo(txSql),
    snapshots: new PgSnapshotRepo(txSql),
    withTransaction: async (innerFn) => {
      // savepoint で nested
      return (txSql as any).savepoint(async (sp: Sql) => runInTx(sp, innerFn));
    },
  };
  return fn(txStorage);
}
```

### 2.2 Layer 違反の解消

#### [LAYER-01] machine/ → runtime/ 逆参照を断つ

- `RecoverableEngineError` / `EntryNotFoundError` / `IrrecoverableEngineError` を **engine 内部** (`katari-engine/src/errors.ts`) に置く。
- `Logger` interface も engine に置く。adapters (consoleLogger, noopLogger) は runtime/ の方に置く。
- 結果: `katari-engine` は `katari-ir` のみに依存。Logger は interface だけなので外部依存を発生させない。

#### [LAYER-02] AgentService 責務分割

- `AgentService` は start / cancel / query / resumeCancelling に専念。
- `OutboundEventDispatcher` クラスを切り出し (`routeOutbound` を移動)。
- `MachineRebuilder` クラスを切り出し (`versionedRollback`, `rebuildAndCache` を移動)。
- `PoisonHandler` クラスを切り出し (`poison` を移動)。

```ts
class AgentService {
  constructor(
    private storage: Storage,
    private registry: MachineRegistry,
    private outboundDispatcher: OutboundEventDispatcher,
    private rebuilder: MachineRebuilder,
    private poisonHandler: PoisonHandler,
    private logger: Logger,
  ) {}
  // ...
}
```

#### [LAYER-03] MachineRegistry のスリム化

- LRU cache の管理だけを残す (`acquire` / `evict`)。
- `getMutex` は別クラス `VersionMutexProvider` に切り出す。
- `replaceHandle` は廃止し、`MachineRebuilder` 側で `acquire` 後に `evict + 再 set` を行う API に置き換え。

### 2.3 機能実装漏れ

#### [IMPL-01] FFI executor

**設計**: HTTP-based sidecar protocol を採用。

```
CORE → POST /__ffi/{module}/{name}     (JSON: args + delegationId)
FFI  → 200 OK with body (= return value JSON) immediately or asynchronously via callback
CORE → POST /__ffi/{delegationId}/terminate
```

実装層: `katari-host/src/ffi-executor.ts`。
- `FFIExecutor` interface (異なる実装を inproc / HTTP / IPC に切替可能)。
- `HttpFFIExecutor`: sidecar HTTP server を起動し、CORE→FFI delegate を `await fetch(...)` し、ack を `MachineHandle.feedEvent` に流す。
- `InProcessFFIExecutor`: テスト用、関数 map で resolve。

タイムアウト機構 ([IMPL-02]) と組合せて運用。

#### [IMPL-02] ExternalThread タイムアウト

**設計**:
1. ExternalThread 構築時に optional `timeoutMs` を引数で受け取る (block.timeoutMs があれば IR から、なければ default e.g. 60s)。
2. host 側 (`katari-host/src/ffi-timeout.ts`) が `setTimeout` を起動して、期限切れ時に `MachineHandle.feedEvent({ kind: "delegateAck", from: "FFI", to: "CORE", delegationId, value: { kind: "tagged", ctorId: ERROR_CTOR, fields: { reason: "timeout" } } })` を打つ。
3. または、より厳格に `MachineHandle.feedEvent({ kind: "terminateAck", ... })` を打って agent を cancel に振る。

**注意**: timer は in-memory なので、process が落ちた場合の保証はない。snapshot に書く必要があるが、絶対時刻 vs 相対時刻の問題を伴う。最小実装は in-memory だけ。

#### [IMPL-03] Parallel for

**設計**:
- 全 iter の child を一度に spawn (現在 array thread の parallel と同じ)。
- 但し `iter vars` を thread の自 scope に書く現状方式は子間で衝突する。
- 解決: `callInline` event に `scopeBindings: Map<VarId, Value>` field を追加し、新 scope の作成時に bindings を直接書き込む。これで各 iteration が独自 scope に iter vars を持つ。
- `for_break` / `for_next` は parallel 下では「最初に for_break した iteration の値を採用、他 iteration を全 cancel」というセマンティクスにする (要言語仕様確定)。
- まずは `for_break` 禁止の parallel for から実装。

#### [IMPL-04] Module DELETE / 取得拡張

- `DELETE /module/:versionId`: agent が無いことを検査 → 削除 (cascade で snapshot, agents)。
- `GET /module/:versionId/ir`: IRModule 全文返却 (debugging)。
- `GET /module/:versionId/schema`: SchemaBundle 全文返却。

#### [IMPL-05] Metrics の wire

- `applyEventDuration.observe(elapsed)`: AgentService.startAgent / cancelAgent の mutex.runExclusive を `performance.now()` で挟む。
- `agentStartTotal.inc()`: `routes/agent.ts` POST handler 末尾。
- `agentCancelTotal.inc()`: `routes/agent.ts` POST cancel handler 末尾。
- `machinesLoaded.set(cache.size)`: registry の `acquire` / `evict` 後に call。

#### [IMPL-06] Recovery の completeness

現在欠けている:
- snapshot あり + cancelling agent → 上記 BUG-01 で解決。
- snapshot あり + running agent + 対応する thread が snapshot に無い (= 完了直前にクラッシュ) → row.state を再評価する必要があるが、engine の真実が分からない。**conservative**: そのような agent は error に flip。

```ts
// recovery: 各 running/cancelling agent について、handle.knowsAgent(delegationId) で生存確認
// snapshot 復元後に APIThread / ExternalThread のいずれかが対応する delegationId を持っているか調べる
// 持っていなければ、agent row を error に flip
```

`MachineHandle.knowsAgent(delegationId): boolean` を追加すれば良い。

### 2.4 Engine 内部の整理

#### [REFACTOR-01] TupleThread / ArrayThread 統合

```ts
abstract class CollectingChildThread<K extends "tuple" | "array"> extends ChildThread {
  abstract readonly resultKind: K;
  // 共通の collected/nextIndex/sequential/parallel ロジック
}

class TupleThread extends CollectingChildThread<"tuple"> { resultKind = "tuple" as const; }
class ArrayThread extends CollectingChildThread<"array"> { resultKind = "array" as const; }
```

#### [REFACTOR-02] Snapshot boilerplate 削減

各 Thread の `serialize` / `restoreSkeleton` / `link` の共通パターンを抽出:

```ts
// Approach A: declarative schema + 共通 serializer
abstract class Thread {
  static serializeFields: SerializeSchema;
  serialize(): SerializedThreadAny {
    return serializeBySchema(this, (this.constructor as any).serializeFields);
  }
}
```

または:

```ts
// Approach B: 各 Thread が "shape" を declare、共通コードが Object.create + assign
```

完全自動化は困難 (variant 固有のフィールドがある) なので、**共通 helper + 各 Thread が固有部分のみ実装** が現実的。

#### [REFACTOR-03] Plain Error → RecoverableEngineError 一掃

以下の箇所を Recoverable に書き換え:

| 場所 | 内容 |
|---|---|
| user.ts:142 | refutable pattern in irrefutable context |
| user.ts:161, 184 | boundary not registered (statementExit / statementCont) |
| handle.ts:168 | no handler for reqId |
| handle.ts:277 | handler body finished without break/next |
| match.ts:60 | no arm matched (既に Recoverable) ✓ |
| user.ts:282 | callTargetValue が closure でない (既に Recoverable) ✓ |
| prim.ts | argument 検証失敗 (大半 Recoverable 化済み) ✓ |
| scope.ts:23, 60 | scope/var not found |

「明白に compiler バグ由来 (本来到達しない)」も基本 Recoverable で良い。1 つの agent の問題で全 version を殺さない。

#### [REFACTOR-04] Pattern bind 場所の統一

- `tryMatch` を `katari-engine/src/pattern.ts` で中心化済 ✓
- 但し各 Thread の `setValueInScope` ループは複数箇所にコピー。`applyBindings(machine, scopeId, bindings)` ヘルパ抽出。

#### [REFACTOR-05] APIThread の generic 化

- 「Root Thread」base class を切り出し、APIThread と (将来の) HTTPRequestThread / ScheduledTriggerThread を統一可能に。
- `RootThread` base に `delegationId` + `pendingOutEvents.push(...Ack)` パターンを集約。

#### [REFACTOR-06] Boundaries / Handlers の immutable 化

- 既に `Object.freeze(...)` で immutable だが、生成のたびに新しいオブジェクトを作っている。
- `extendBoundaries` の単一インスタンス再利用 (memoization) で GC 圧減。優先度低。

### 2.5 公開 API の絞り込み

#### [API-01] runtime の export を整理

```ts
// katari-runtime/src/index.ts (after refactor)
export { MachineHandle } from "./handle.js";
export type { MachineSnapshot } from "./snapshot.js";
export type { Logger, LogLevel } from "./logger.js";
export { buildConsoleLogger, consoleLogger, noopLogger } from "./logger.js";
export {
  RecoverableEngineError,
  IrrecoverableEngineError,
  EntryNotFoundError,
} from "./errors-host.js";

// re-exports from katari-ir / katari-engine (selective)
export type { IRModule, BlockId, QualifiedName, SchemaBundle, AgentDefinition, JsonSchema } from "katari-ir";
export type { Value, MachineEvent, MachineEventPayload, Endpoint, ThreadId, ScopeId, DelegationId, EscalationId } from "katari-engine";
export { createDelegationId, createThreadId, createScopeId } from "katari-engine";
```

Thread サブクラスは export しない。`SerializedScope` 等の snapshot 内部型も export しない (`MachineSnapshot` だけが I/O 境界)。

#### [API-02] api-server index.ts も削減

- `MachineRegistry` / `AgentService` / `ModuleService` は public で良い (テスト用)。
- `recoverOnBoot` も public。
- `InMemoryStorage` / `PostgresStorage` は public (テスト・wiring 用)。
- Storage interface 型は public。
- `AgentRow` / `AgentState` も public (HTTP response shape として)。

### 2.6 横断的改善

#### [CROSS-01] ID 生成の DI 化

```ts
type IdGenerators = {
  threadId: () => ThreadId;
  scopeId: () => ScopeId;
  delegationId: () => DelegationId;
};
```

`MachineState` に保持し、テストで決定的 (counter 形式) にできるように。

#### [CROSS-02] Time injection

`recoverOnBoot` の "now" 等で `() => Date.now()` を inject 可能に (test 容易性)。

#### [CROSS-03] Storage の granular tx

各 Repo の callsite で `withTransaction` を呼ぶ現状から、各 Repo メソッドが optional tx を受け取る形へ。

```ts
class PgAgentRepo {
  async insert(row: AgentRow, tx?: TransactionSql): Promise<void> { ... }
}
```

これにより、`AgentService` は明示的に tx を持ち回す。`Storage` interface はこの方式に合わせて refactor。

代替案: AsyncLocalStorage で tx を context-bound にする。

#### [CROSS-04] OpenAPI / 型生成

- routes / validation を OpenAPI schema に書き直し、TypeScript SDK を自動生成可能に。
- Hono は `@hono/zod-openapi` を使えば routes と schema を統合できる。

#### [CROSS-05] Observability の充実

- structured logging に統一 (現在の console.log + level prefix → JSON line)。
- correlation id (X-Request-Id) の伝搬。
- AgentService の各 step に span 出力 (OpenTelemetry compatibility)。

#### [CROSS-06] Configuration centralization

`katari-api-server/src/config.ts` を新設し:

```ts
export const Config = {
  databaseUrl: requireEnv("DATABASE_URL"),
  port: parseIntEnv("PORT", 8080),
  logLevel: parseLogLevelEnv("LOG_LEVEL", "info"),
  apiKey: requireEnv("KATARI_API_KEY"),
  machineCacheMax: parseIntEnv("KATARI_MACHINE_CACHE_MAX", 64),
  rateLimitCapacity: parseIntEnv("KATARI_RATE_LIMIT_CAPACITY", 60),
  rateLimitRefillPerSecond: parseFloatEnv("KATARI_RATE_LIMIT_REFILL", 1),
  ffiTimeoutMs: parseIntEnv("KATARI_FFI_TIMEOUT_MS", 60000),
};
```

`bin.ts` は `Config` を import して各層に渡すだけにする。

### 2.7 Test infrastructure

#### [TEST-01] Recovery cancelling resume の test

`tests/recovery-cancelling-resume.test.ts`:
1. agent を `running` で start
2. cancelAgent → state=cancelling
3. snapshot 取得
4. machine evict → 別プロセス想定
5. recovery 走行
6. agent state=cancelled になること

#### [TEST-02] Rollback race の test

concurrent startAgent + applyEvent throw を仕掛け、rollback と次 acquire の race を確認。

#### [TEST-03] FFI executor integration test

inproc FFI executor + timeout の組合せ。

#### [TEST-04] Property-based testing

`fast-check` を導入し、Thread state machine が任意の event sequence で invariant を保つことを検証。
- invariant 1: 全 thread の parent chain が threads map に解決可能
- invariant 2: 全 child の parent.children に自分が登録されている
- invariant 3: boundaries の slot は正しい variant のみ
- invariant 4: snapshot → restore → snapshot で同一 (idempotent)

---

## 3. 優先度付き実装ロードマップ

時間無限の前提でも、依存関係順に並べる:

### Phase A: 致命バグ修正 (最優先)

1. [BUG-01] Recovery cancelling resume
2. [BUG-02] versionedRollback await 化
3. [BUG-03] Postgres nested tx
4. [TEST-01] [TEST-02] regression test 追加

### Phase B: Layer 整理

5. パッケージ分割: `katari-ir` / `katari-engine` / `katari-runtime` / `katari-host` / `katari-storage` / `katari-api-server`
6. [LAYER-01] 循環依存解消
7. [LAYER-02] AgentService 分割
8. [LAYER-03] MachineRegistry スリム化
9. [API-01] [API-02] export 絞り込み
10. [TEST-04] property-based test 整備

### Phase C: 重要機能実装

11. [IMPL-01] FFI executor (HTTP / inproc)
12. [IMPL-02] ExternalThread timeout
13. [IMPL-06] Recovery completeness
14. [TEST-03] FFI integration test

### Phase D: コード品質改善

15. [REFACTOR-01] TupleThread / ArrayThread 統合
16. [REFACTOR-02] Snapshot boilerplate
17. [REFACTOR-03] Recoverable error 化
18. [REFACTOR-04] [REFACTOR-05] [REFACTOR-06]
19. [CROSS-01] [CROSS-02] [CROSS-03] DI / time injection / granular tx
20. [CROSS-06] Configuration centralization

### Phase E: 機能拡張

21. [IMPL-03] Parallel for
22. [IMPL-04] Module DELETE / IR 取得 endpoints
23. [IMPL-05] Metrics wire-up
24. [CROSS-04] OpenAPI 型生成
25. [CROSS-05] Observability (OpenTelemetry)

### Phase F: 中長期再設計検討

- **Event sourcing**: snapshot 一括書き換えの代替として、event log + periodic snapshot にする。FFI in-flight の復元が容易になる。
- **Multi-process scaling**: 単一プロセスの mutex 直列化を超えて、同一 version で複数プロセスが処理する形態 (DB-level lock or pg-advisory)。
- **Engine の言語移植**: pure engine は logic だけなので Rust / Go 等への移植も検討余地あり。
- **Streaming snapshot**: 大規模 IR + 多 agent の場合、snapshot を JSONL streaming に。

---

## 4. 各項目の見積りと依存関係

| ID | 概算工数 | 依存 | 影響範囲 |
|---|---|---|---|
| BUG-01 | 1d | (なし) | recovery |
| BUG-02 | 0.5d | (なし) | agent-service |
| BUG-03 | 1d | (なし) | storage/pg |
| LAYER-01 | 2-3d | (なし) | runtime/machine |
| LAYER-02 | 3-5d | LAYER-01 | api-server/services |
| LAYER-03 | 1-2d | LAYER-02 | api-server/registry |
| API-01 | 1d | LAYER-01 | runtime/index |
| IMPL-01 | 1-2w | LAYER-01..03 | host (新パッケージ) |
| IMPL-02 | 3-5d | IMPL-01 | host/ffi-timeout |
| IMPL-06 | 2-3d | BUG-01 | recovery |
| REFACTOR-01 | 1-2d | (なし) | engine/thread |
| REFACTOR-02 | 1-2w | (なし) | engine/thread (大改造) |
| REFACTOR-03 | 1-2d | (なし) | engine 全域 |
| TEST-04 | 3-5d | LAYER-01 | tests/ |
| CROSS-01..06 | 各 1-3d | LAYER-* | 全域 |

---

## 5. リスク

- **大規模 refactor 中の機能停止リスク**: 非公開段階なので問題なし。
- **API 互換破壊**: 非公開段階なので問題なし。
- **DB スキーマ変更**: 必要なら DROP & re-create。マイグレーション不要。
- **テストカバレッジ低下**: refactor 前にテストを充実させる (Phase A の TEST-01/02、Phase B の TEST-04)。

---

## 6. 結論

現在のコードベースは **中核 state machine の設計が秀逸** だが、外側 (host / api-server) の責務肥大と複数の致命バグを抱えている。"1 から作り直す" 前提では:

1. **engine / runtime / host / storage / api-server** の 5 パッケージ分割 で層境界を物理化する。
2. **致命バグ 3 件** (Recovery cancelling, rollback race, nested tx) を最優先で潰す。
3. **FFI executor + timeout** を本番運用前に実装する。
4. AgentService の責務を 4 つのクラス (AgentService / OutboundDispatcher / Rebuilder / PoisonHandler) に分割する。
5. Public API を MachineHandle 中心に絞り込み、Thread サブクラスは internal。
6. property-based test で state machine の invariant を継続検証。

これらを通じて、**コアエンジンの抽象的な美しさを保ちながら、外側を運用堪える形に再構築** することを目指す。
