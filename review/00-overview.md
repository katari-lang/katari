# katari-runtime / katari-api-server コード評価 — 総括

評価日: 2026-05-08
対象: `typescript/packages/katari-runtime/`, `typescript/packages/katari-api-server/`
ファイル数: runtime 24 ts ファイル / api-server 16 ts ファイル
行数: runtime ~4760 行 / api-server ~2800 行

## ドキュメント構成

| ファイル | 内容 |
|---|---|
| [00-overview.md](00-overview.md) | 本文書。全体総括と読み方ガイド。 |
| [01-phase1-architecture.md](01-phase1-architecture.md) | Phase 1: ライブラリ・モジュール責務と全体設計の評価 |
| [02-phase2-modules.md](02-phase2-modules.md) | Phase 2: 各モジュールの詳細評価 (バグ・実装漏れ・責務違反) |
| [03-phase3-refactor-plan.md](03-phase3-refactor-plan.md) | Phase 3: リファクタリング・バグ修正・実装計画 |

## エグゼクティブサマリ

**Pros**:
- IR JSON / state machine / facade / I/O / persistence の 5 層分けは概ね健全。
- Thread 階層は template method + 仮想ディスパッチでよくモジュール化されている (`runner.ts` に IR factory 以外の switch が無い)。
- Boundary 機構 (`exitKindReturn` 等の slot 化) と handlers map (型レベルで HandleThread に narrow) は型レベル安全。
- Snapshot による永続化と per-version mutex + Storage transaction による並行制御は、競合・クラッシュに対し堅実。
- Phase 別エラー分類 (`RecoverableEngineError` / `Irrecoverable`) と routing がストーリーとして成立。

**主要な問題点 (Phase 2 の詳細を要約)**:

1. **層境界違反**: `katari-runtime/src/machine/` が `runtime/errors.ts` と `runtime/logger.ts` を import している (machine ↔ runtime の循環依存)。`runtime/` は `machine/` のラッパとして設計されているはずなのに、逆向きの参照が混在している。
2. **致命バグ — Recovery が cancelling agent を resume できない**: [recovery.ts:90](../typescript/packages/katari-api-server/src/recovery.ts#L90) で `agents.cancelAgent(row.id)` を呼ぶが、`cancelAgent` 内の `setState(..., expectedState: "running")` が `cancelling` に対しては不一致で no-op となり、エンジン側の terminate が永遠に発行されない。
3. **致命バグ — `versionedRollback` が fire-and-forget**: [agent-service.ts:330](../typescript/packages/katari-api-server/src/services/agent-service.ts#L330) `void this.rebuildAndCache(...).catch(...)` が mutex 内で await されないため、rollback 完了前に次の `acquire` が実行され古いハンドルを掴むレースがある。
4. **致命バグ — Postgres nested transaction が savepoint を貼らない**: [pg.ts:335](../typescript/packages/katari-api-server/src/storage/pg.ts#L335) `withTransaction: this.withTransaction.bind(this)` は外側の pool から新規 BEGIN を発行するため、ネストすると独立した transaction になる (コメントの主張と矛盾)。
5. **External delegate にタイムアウトなし**: FFI 側がレスポンスを返さないと agent が永遠に running のまま。dead-letter / timeout / re-issue の仕組みが無い。
6. **未実装機能**: parallel for / FFI executor / module 削除 / IR の取得エンドポイント。
7. **責務分散の問題**: `AgentService` (402 行) が start/cancel/query/route-outbound/rollback/poison を全て持つ。`MachineRegistry` も cache + mutex + replace を兼任。
8. **Public API 過剰露出**: `katari-runtime/src/index.ts` が Thread サブクラスから `SerializedScope` まで全て re-export しているため、内部実装変更に対する API 互換の壁が高くなっている。

## 推奨アクション (Phase 3 の要約)

`時間が無限・1 から作り直し前提` という制約を生かし、以下の大規模変更を推奨:

- **Layer の clean separation**: `pure-engine` (今の `machine/` 相当だが logger/errors 依存ゼロ) / `runtime-facade` / `host-adapter` の 3 つに分離。
- **Effect / Outbound の dispatcher 化**: 現在 `AgentService.routeOutbound` に詰まっている翻訳ロジックを、engine 直近の OutboundRouter として独立させる。
- **Snapshot 経由でない state machine 復元 = event sourcing 検討**: スナップショットだけだと FFI in-flight の復元が困難。event log との併用に振る価値がある。
- **Thread 階層の整理**: ArrayThread と TupleThread の重複を `CollectingChildThread<T>` で統一。Snapshot boilerplate は decorator / mixin で剥がす。
- **Recovery の再設計**: `cancelling` 中の agent を re-cancel する独立メソッド (engine への直接 `terminate` event 注入) を切り出す。
- **FFI executor の事前実装**: 現状の "FFI 来たら Recoverable で死ぬ" は本番運用前提では機能不足。HTTP / IPC / inproc いずれかの sidecar を選定。
- **Public API の絞り込み**: 外向け symbol を MachineHandle + 型 + Thread enum のみに留め、Thread サブクラスの class export は止める。

詳細は [03-phase3-refactor-plan.md](03-phase3-refactor-plan.md) を参照。
