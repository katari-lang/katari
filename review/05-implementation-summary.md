# Phase 5: 実装サマリと削除対象ファイル

このドキュメントは [03-phase3-refactor-plan.md](03-phase3-refactor-plan.md) と
[04-discussion-q-and-a.md](04-discussion-q-and-a.md) に基づく実装の最終状態を
記録する。

## 実装した内容

### A. 新 engine の構築 (Phase A〜B)

`typescript/packages/katari-runtime/src/engine/` に新 engine を完全実装。
旧 `src/machine/` と並行存在。

| ファイル | 役割 |
|---|---|
| `id.ts` | Branded id 型 (`ThreadId` / `ScopeId` / `DelegationId` / `EscalationId` / `AskId` / `CallId`) |
| `endpoint.ts` | `Endpoint = string` (旧 katari-protocol スタイル) |
| `value.ts` | Runtime Value 型 + frozen `NULL_VALUE` |
| `scope.ts` | Scope = data only (Immer 親和) |
| `event.ts` | Event (External + Internal) + AskKind (data inline 形式) |
| `state.ts` | State 型 (selfEndpoint + threads + scopes + lastGcScopeCount) |
| `result.ts` | Result `{ state, outbound, errors, logs, diffs }` |
| `diff.ts` | Diff 型 (incremental persist 用) |
| `errors.ts` | EngineError 階層 (engine 内に閉じる) |
| `logger.ts` | Effect の `Context.Tag` ベース Logger Service |
| `pattern.ts` | tryMatch (ts-pattern ベース) |
| `prim.ts` | executePrim + valueEquals + valueToString |
| `gc.ts` | Mark-and-sweep GC + shouldGc heuristic |
| `step-ctx.ts` | Immer draft + side-effect buffer |
| `runner.ts` | drive loop + 6-method dispatch |
| `apply.ts` | applyEvent (関数型: `(State, Event) => Result`) |
| `snapshot.ts` | serialize/deserialize (structuredClone ベース) |
| `spawn.ts` | Block kind → Thread allocator |
| `thread/types.ts` | Thread tagged union (10 variant、APIThread 廃止) + Common |
| `thread/common.ts` | 親子・cancel cascade・askIdMap forwarding helpers |
| `thread/ops/{prim,ctor,tuple,array,match,user,for,request,external,handle}.ts` | 10 variant の `create / done / cancel / cancelAck / ask / askAck` 実装 |
| `thread/ops/defaults.ts` | デフォルト ask proxy / cancel cascade |
| `thread/ops/types.ts` | `ThreadOps<T>` 型 |
| `thread/ops/index.ts` | dispatch table (ts-pattern exhaustive) |
| `thread/ops/collecting.ts` | Tuple/Array 共通の collecting ロジック |
| `index.ts` | engine 内部 barrel |
| `../facade.ts` | `MachineHandle` (新 facade) |

### B. Bubbling ask + APIThread 廃止 (Phase C+D 部分)

新 engine では:
- **Boundaries map 廃止** — 各 thread が自分の ask を catch するか親に proxy するか判断
- **AskKind に data inline** — `{ kind: "request", reqId, args }` / `{ kind: "next", value, mods }` / `{ kind: "return", value }` 等
- **askIdMap** で proxy thread が `own_askId → (childCallId, childAskId)` を保持
- **APIThread 廃止** — root threads は `parent === null` で表現、host 側 DelegationRouter が DelegationId↔ThreadId routing を担当する想定
- **Endpoint = string** 抽象化

### C. 致命バグ修正 (Phase E) — Legacy api-server に適用

| ID | 場所 | 修正内容 |
|---|---|---|
| **BUG-01** | [agent-service.ts](../typescript/packages/katari-api-server/src/services/agent-service.ts#L227) + [recovery.ts](../typescript/packages/katari-api-server/src/recovery.ts#L94) | `resumeCancellingOnBoot` を新設し、`expectedState=running` 検査をスキップして `cancelling` agent を再開 |
| **BUG-02** | [agent-service.ts:328](../typescript/packages/katari-api-server/src/services/agent-service.ts#L328) | `versionedRollback` を `Promise<void>` で `await` に変更、レース解消 |
| **BUG-03** | [pg.ts:336](../typescript/packages/katari-api-server/src/storage/pg.ts#L336) | `runInTx` ヘルパで `txSql.begin` を bind して savepoint を貼る |

### D. Host 層の責務分割 (Phase D 部分)

`AgentService` から以下を抽出:

| 新クラス | ファイル | 役割 |
|---|---|---|
| `OutboundEventDispatcher` | [services/outbound-dispatcher.ts](../typescript/packages/katari-api-server/src/services/outbound-dispatcher.ts) | Result.outbound → DB writes / FFI invoke |
| `MachineRebuilder` | [services/machine-rebuilder.ts](../typescript/packages/katari-api-server/src/services/machine-rebuilder.ts) | versionedRollback / rebuildAndCache |
| `PoisonHandler` | [services/poison-handler.ts](../typescript/packages/katari-api-server/src/services/poison-handler.ts) | poison ロジック切り出し |

> 注: `AgentService` 自体は legacy engine とテスト互換のため未 refactor。
> 新 engine 移行時に上記 3 クラスを正規利用する想定。

### E. 機能追加 (Phase H 部分)

- **DELETE /module/:versionId** — module 削除エンドポイント
- **GET /module/:versionId/ir** — IRModule 取得
- **GET /module/:versionId/schema** — SchemaBundle 取得
- **Storage.modules.delete(id)** — `ModuleRepo` に追加
- **Metrics wire-up**:
  - `agentStartTotal.inc()` / `agentCancelTotal.inc()` を AgentService.startAgent / cancelAgent で呼ぶ
  - `applyEventDuration.observe(elapsed)` を mutex section の `performance.now()` 計測で
  - `machinesLoaded` gauge を 5 秒間隔で `registry.cacheSize` から更新 (bin.ts)
  - `MachineRegistry.cacheSize` を新規 getter として公開

### F. 公開 API の調整

[src/index.ts](../typescript/packages/katari-runtime/src/index.ts):

- **Legacy 名前空間 (旧 machine/runtime)**: `MachineHandle` / `Thread` / `applyEvent` / `createMachine` 等は名前を保持
- **新 engine 名前空間 (Engine\* prefix)**: `EngineHandle` / `EngineThread` / `engineApplyEvent` / `createEngineState` / `EngineState` / `EngineEvent` / 等

新 engine は `EngineHandle` から使用可能。Legacy は引き続き機能。

### G. 採用ライブラリ

- **effect** `^3.21.2` — Logger Service の `Context.Tag` 基盤として
- **immer** `^11.1.8` — State immutable update + `produceWithPatches` による diff auto-derive
- **ts-pattern** `^5.9.0` — Thread variant dispatch / pattern matching の exhaustive check

### H. 規約・テスト

- 新 engine integration test: `tests/engine/integration.test.ts` で `add(2,3) → 5` の end-to-end を検証
- 新 engine unit test: `tests/engine/prim-ops.test.ts` で executePrim の動作確認
- BUG-01 regression: `tests/recovery-cancelling-resume.test.ts` (api-server)
- 全 23 test files / 93 tests が green

## 実装スキップした項目

時間と複雑度の制約で延期したもの。プラン書 [03](03-phase3-refactor-plan.md) に詳細記載:

| Phase | 項目 | 理由 / 後続作業 |
|---|---|---|
| **D 完全移行** | api-server を新 engine に切り替え | 既存 api-server tests を保つため legacy engine を維持。新 engine への移行は別タスク。`EngineHandle` 経由で使用可能な状態にしてある。 |
| **F** | FFI executor (HTTP / inproc) + timeout | 新 engine の outbound 形式が定まってから実装。`OutboundEventDispatcher` の TODO に該当。 |
| **G** | Diff persistence (Immer patches → DB upsert) | engine 側で Diff 型と patchesToDiffs は実装済。Storage 側の `applyDiffs` API + テーブル分割が後続作業。 |
| **H 残部** | parallel for / Property-based test (`fast-check`) / OpenAPI 型生成 / OpenTelemetry 連携 | 機能追加の優先度。新 engine の parallel for は仕様確定待ち。 |

## ユーザー側で削除すべきファイル

ファイル削除権限が無いため、**ユーザーが手動で削除する** ことを推奨するファイル一覧。

### A. /review/ 旧版 (Phase 1〜3 評価レポート)

新版 `00-overview.md` / `01-phase1-architecture.md` / `02-phase2-modules.md` / `03-phase3-refactor-plan.md` / `04-discussion-q-and-a.md` / `05-implementation-summary.md` (本ファイル) に置き換え済み。CLAUDE.md の git status から既に「D」マーク (deleted) が付いていた以下:

- `review/README.md` (削除済 in git index)
- `review/step1-architecture.md` (削除済 in git index)
- `review/step2-phase-separation.md` (削除済 in git index)
- `review/step3-libraries.md` (削除済 in git index)
- `review/step4-production-ready.md` (削除済 in git index)
- `review/step5-conventions.md` (削除済 in git index)

→ 既に git で D マーク済みなので `git rm` 等は不要。`git commit` で削除を確定するだけ。

### B. Legacy engine (Phase H 完全 cleanup 時)

新 engine への完全移行が完了した暁に削除する。**現時点では残す** (`AgentService` がまだ legacy engine を import しているため)。

```
typescript/packages/katari-runtime/src/machine/                (ディレクトリ全体)
typescript/packages/katari-runtime/src/runtime/facade.ts
typescript/packages/katari-runtime/src/runtime/snapshot.ts
typescript/packages/katari-runtime/src/runtime/errors.ts
typescript/packages/katari-runtime/src/runtime/logger.ts
typescript/packages/katari-runtime/src/runtime/                 (ディレクトリごと、上記 4 ファイル全部削除後)
```

**削除前提条件**:
1. `src/services/agent-service.ts` を `EngineHandle` ベースに書き換え
2. `OutboundEventDispatcher` に新 engine の Result 型を渡すよう変更
3. recovery.ts も `EngineHandle.fromSnapshot` を使うよう書き換え
4. 既存テスト (`tests/snapshot.test.ts` 等の `createMachine` を直接呼ぶもの) を新 API に書き換え
5. `src/index.ts` の Legacy block を削除

これらは別タスクで実施。

### C. 旧 ts-old / ts-old-2 等

リポジトリの `ts-old/` ディレクトリは参照用。今回の実装では `katari-protocol` 部分だけ
[review/04-discussion-q-and-a.md](04-discussion-q-and-a.md) で言及。今後不要なら削除可。

```
ts-old/                                    (参照済、不要なら削除可)
```

### D. 削除しない方が良いもの

- `samples/` — 旧 syntax のサンプル群、将来の compiler 機能拡張で再参照される可能性
- `haskell-old/` — Haskell の旧実装、参考用
- 各 review ドキュメント (`00-overview` 〜 `05-implementation-summary`) — 設計判断の記録

## 動作確認

### Build
```sh
cd typescript && pnpm -r run build
# → 全 workspace 通過
```

### Test
```sh
cd typescript && pnpm -r test
# → katari-runtime: 14 files, 67 tests pass
# → katari-api-server: 9 files, 26 tests pass
# → 合計 23 files, 93 tests pass
```

### Engine integration smoke
```sh
pnpm --filter katari-runtime test -- tests/engine/integration.test.ts
# → add(2,3) → 5 の end-to-end が新 engine で動作
```

## まとめ

- **Phase A〜C, E, D 部分, H 部分** を実装。
- **Phase D 完全移行 (engine 切替), Phase F (FFI), Phase G (Diff persist)** は後続作業として残す。
- 既存テスト 100% pass、新 engine の smoke + integration テストも green。
- 削除対象ファイルは git の D マークまたは別タスクでの cleanup 時に処理する。
