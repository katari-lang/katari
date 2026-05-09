# Phase 5: 実装サマリ (Phase A〜H 全完了)

このドキュメントは [03-phase3-refactor-plan.md](03-phase3-refactor-plan.md) と
[04-discussion-q-and-a.md](04-discussion-q-and-a.md) に基づく実装の最終状態を
記録する。

## 実装した内容

### A. 新 engine の構築 (Phase A〜B)

`typescript/packages/katari-runtime/src/engine/` に新 engine を完全実装。
旧 `src/machine/` と `src/runtime/` は **完全削除**。

| ファイル | 役割 |
|---|---|
| `id.ts` / `endpoint.ts` / `value.ts` / `scope.ts` | 基本型 (brand 化 + Endpoint=string) |
| `event.ts` | Event (External + Internal) + AskKind (data inline 形式) |
| `state.ts` / `result.ts` / `diff.ts` | State / Result / Diff 型 |
| `errors.ts` / `logger.ts` | EngineError 階層 + Effect Logger Service |
| `pattern.ts` / `prim.ts` | tryMatch / executePrim (ts-pattern ベース) |
| `step-ctx.ts` | Immer draft + side-effect buffer + JSON-detach |
| `runner.ts` / `apply.ts` | drive loop + applyEvent + 外部 event 翻訳 |
| `gc.ts` | Mark-and-sweep GC + shouldGc heuristic |
| `spawn.ts` | Block kind → Thread allocator |
| `snapshot.ts` | structuredClone ベースの serialize/deserialize |
| `thread/types.ts` / `thread/common.ts` | Thread tagged union (10 variant) + 共通 helper |
| `thread/ops/{prim,ctor,tuple,array,match,user,for,request,external,handle}.ts` | 10 variant の `create / done / cancel / cancelAck / ask / askAck` 実装 |
| `thread/ops/defaults.ts` | デフォルト ask proxy / cancel cascade |
| `thread/ops/types.ts` / `index.ts` | `ThreadOps<T>` 型 + dispatch table |
| `thread/ops/collecting.ts` | Tuple/Array 共通 collecting ロジック |
| `../facade.ts` | `MachineHandle` / `EngineHandle` (新 facade) |

### B. Bubbling ask + APIThread 廃止 (Phase C+D)

新 engine では:
- **Boundaries map 廃止** — 各 thread が自分の ask を catch するか親に proxy するか判断
- **AskKind に data inline** — `{ kind: "request", reqId, args }` / `{ kind: "next", value, mods }` / `{ kind: "return", value }` 等
- **askIdMap** で proxy thread が `own_askId → (childCallId, childAskId)` を保持
- **APIThread 廃止** — root threads は `parent === null` で表現
- **Endpoint = string** 抽象化 (旧 katari-protocol スタイル)
- **外部 event 翻訳**: `applyEvent` が直接 `delegate API→CORE` / `delegateAck FFI→CORE` 等の外部 event を受け付けて内部 event に翻訳。`apiDelegations` / `ffiDelegations` map を State に持つ。

### C. 致命バグ修正 (Phase E)

| ID | 場所 | 修正内容 |
|---|---|---|
| **BUG-01** | [agent-service.ts](../typescript/packages/katari-api-server/src/services/agent-service.ts) + [recovery.ts](../typescript/packages/katari-api-server/src/recovery.ts) | `resumeCancellingOnBoot` を新設し、`expectedState=running` 検査をスキップして `cancelling` agent を再開 |
| **BUG-02** | [agent-service.ts](../typescript/packages/katari-api-server/src/services/agent-service.ts) | `versionedRollback` を `Promise<void>` で `await` に変更、レース解消 |
| **BUG-03** | [pg.ts](../typescript/packages/katari-api-server/src/storage/pg.ts) | `runInTx` ヘルパで `txSql.begin` を bind して savepoint を貼る |

### D. Host 層の責務分割 (Phase D)

`AgentService` から以下を抽出 + 完全な engine 移行:

| クラス | ファイル | 役割 |
|---|---|---|
| `OutboundEventDispatcher` | [services/outbound-dispatcher.ts](../typescript/packages/katari-api-server/src/services/outbound-dispatcher.ts) | Result.outbound → DB writes / FFI invoke |
| `MachineRebuilder` | [services/machine-rebuilder.ts](../typescript/packages/katari-api-server/src/services/machine-rebuilder.ts) | versionedRollback / rebuildAndCache |
| `PoisonHandler` | [services/poison-handler.ts](../typescript/packages/katari-api-server/src/services/poison-handler.ts) | poison ロジック切り出し |

`AgentService` 内部は新 engine の `EngineHandle` を直接使用。`routeOutbound` は `EngineEvent` (新 shape) を処理。

### E. FFI executor (Phase F)

| ファイル | 役割 |
|---|---|
| [ffi/executor.ts](../typescript/packages/katari-api-server/src/ffi/executor.ts) | `FFIExecutor` interface + `withTimeout` ヘルパ |
| [ffi/inproc.ts](../typescript/packages/katari-api-server/src/ffi/inproc.ts) | `InProcessFFIExecutor` (テスト用、関数 map) |
| [ffi/http.ts](../typescript/packages/katari-api-server/src/ffi/http.ts) | `HttpFFIExecutor` (本番、HTTP+JSON sidecar) |

`AgentService` に `ffi: FFIExecutor` 引数 + `dispatchFFIDelegate` / `dispatchFFITerminate` / `feedFFIAck` / `feedFFITerminateAck` メソッド + `drainFFI()` (テスト/シャットダウン用)。失敗時は cancelAgent → terminateAck で agent を cancelled に遷移。

### F. Diff persistence (Phase G)

`Storage.diffs: DiffRepo` を追加 (interface + Pg + Memory 実装):
- `append(versionId, diffs)` — applyEvent 完了時に呼ぶ
- `list(versionId)` — recovery 時に再生 (将来用)
- `delete(versionId)` — poison 時にクリア

新 SQL テーブル `machine_diffs` (BIGSERIAL + JSONB)。

`AgentService` の各 mutex section で `tx.diffs.append(versionId, out.diffs)` を `tx.snapshots.upsert` と並んで呼ぶ。

### G. Parallel for + 機能追加 (Phase H)

- **Parallel for 実装**: `block.parallel === true` の for-loop を全 iteration 同時 spawn。各 iteration が独自 inline scope を持ち、iter vars を per-iteration scope に bind して race を回避。
- **DELETE /module/:versionId** — module 削除エンドポイント
- **GET /module/:versionId/ir** — IRModule 取得
- **GET /module/:versionId/schema** — SchemaBundle 取得
- **Storage.modules.delete(id)** — `ModuleRepo` に追加
- **Metrics wire-up**:
  - `agentStartTotal.inc()` / `agentCancelTotal.inc()` を AgentService.startAgent / cancelAgent で呼ぶ
  - `applyEventDuration.observe(elapsed)` を mutex section の `performance.now()` 計測で
  - `machinesLoaded` gauge を 5 秒間隔で `registry.cacheSize` から更新 (bin.ts)
  - `MachineRegistry.cacheSize` を新規 getter として公開

### H. 公開 API の整理

[src/index.ts](../typescript/packages/katari-runtime/src/index.ts):

- `MachineHandle` (= EngineHandle alias) を主要 entry point として export
- 旧 legacy 名 (`MachineEvent` / `MachineState` / `MachineSnapshot`) は新型の type alias として残す (api-server 互換のため)
- 旧 `runtime/` `machine/` モジュールは **完全削除**

### I. 採用ライブラリ

- **effect** `^3.21.2` — Logger Service の `Context.Tag` 基盤として
- **immer** `^11.1.8` — State immutable update + `produceWithPatches` で diff auto-derive
- **ts-pattern** `^5.9.0` — Thread variant dispatch / pattern matching の exhaustive check

## 動作確認

### Build
```sh
cd typescript && pnpm -r run build
# → 全 workspace 通過
```

### Test
```sh
cd typescript && pnpm -r test
# → katari-runtime: 2 files, 8 tests pass
# → katari-api-server: 11 files, 30 tests pass
# → 合計 13 files, 38 tests pass
```

### テスト一覧

#### katari-runtime
- `engine/integration.test.ts` (3 tests) — end-to-end via external delegate
- `engine/prim-ops.test.ts` (5 tests) — prim primitive ops + valueEquals

#### katari-api-server
- `auth-and-rate-limit.test.ts` (10 tests)
- `cancel-e2e.test.ts` (1 test)
- `compiler-roundtrip.test.ts` (1 test)
- `concurrent-registry.test.ts` (2 tests)
- `diff-persistence.test.ts` (2 tests) — Phase G regression
- `end-to-end.test.ts` (4 tests)
- `ffi-executor.test.ts` (2 tests) — Phase F regression
- `poison.test.ts` (1 test)
- `recoverable-error.test.ts` (3 tests)
- `recovery-cancelling-resume.test.ts` (2 tests) — BUG-01 regression
- `snapshot-recovery.test.ts` (2 tests)

## 実装した Phase 一覧

| Phase | 内容 | 状態 |
|---|---|---|
| **A** | 依存追加 (effect / immer / ts-pattern) + engine/ スキャフォルド | ✅ |
| **B** | 新 engine 完全実装 (10 variant ops + GC + snapshot + facade + integration test) | ✅ |
| **C** | Bubbling ask migration (boundaries 廃止、AskKind data inline、askIdMap proxy) | ✅ |
| **D** | APIThread 廃止 + Host 層構築 + AgentService の新 engine 完全移行 + Legacy 削除 | ✅ |
| **E** | 致命バグ 3 件修正 + regression test | ✅ |
| **F** | FFI executor (InProc + HTTP + timeout + drainFFI + e2e test) | ✅ |
| **G** | Diff persistence (DiffRepo API + Pg/Memory 実装 + machine_diffs テーブル) | ✅ |
| **H** | parallel for + DELETE module + IR/schema GET + metrics wire + cacheSize | ✅ |

## 後続検討項目

- **Diff replay-based recovery**: 現在 `recoverOnBoot` は snapshot のみ使用。`storage.diffs.list()` を再生する形式への切替は別タスク。
- **Property-based testing**: `fast-check` での invariant 検証 (Inv1-4) は未実装。
- **OpenAPI 型生成**: `@hono/zod-openapi` への切替は未実装。
- **OpenTelemetry**: tracing / metrics export は未実装 (現状はカスタム metrics)。
- **Recovery completeness (IMPL-06)**: snapshot にあるが engine state 上に対応 thread が無い agent の検出は未実装 (`MachineHandle.knowsAgent` 等)。

## ユーザー側で削除済みファイル

git rm 完了:

```
typescript/packages/katari-runtime/src/machine/                (全ディレクトリ)
typescript/packages/katari-runtime/src/runtime/                (全ディレクトリ)
typescript/packages/katari-runtime/tests/array-tuple.test.ts
typescript/packages/katari-runtime/tests/bind-pattern.test.ts
typescript/packages/katari-runtime/tests/cancel-race.test.ts
typescript/packages/katari-runtime/tests/error-taxonomy.test.ts
typescript/packages/katari-runtime/tests/external-idempotent.test.ts
typescript/packages/katari-runtime/tests/for.test.ts
typescript/packages/katari-runtime/tests/gc.test.ts
typescript/packages/katari-runtime/tests/handle.test.ts
typescript/packages/katari-runtime/tests/match.test.ts
typescript/packages/katari-runtime/tests/prim.test.ts
typescript/packages/katari-runtime/tests/request-thread-snapshot.test.ts
typescript/packages/katari-runtime/tests/snapshot.test.ts
review/README.md (既に D マーク済)
review/step1-architecture.md (既に D マーク済)
review/step2-phase-separation.md (既に D マーク済)
review/step3-libraries.md (既に D マーク済)
review/step4-production-ready.md (既に D マーク済)
review/step5-conventions.md (既に D マーク済)
```

`ts-old/` は任意削除のため残してある (参照用)。

## まとめ

- **Phase A〜H 完全実装**。
- 新 engine が legacy engine を完全置換。Endpoint 抽象化、bubbling ask、APIThread 廃止、6-method Thread interface 全て実現。
- 致命バグ 3 件 + FFI executor + Diff persistence + parallel for + Module DELETE + Metrics 全て実装済。
- 全 38 テスト pass。
- レガシーコード + 関連テスト 完全削除済 (git rm)。
