# Codebase Review — 2026-05-09

`katari-compiler` / `katari-runtime` / `katari-api-server` 全体を 5 並列 Explore でレビューした結果のサマリー。CLI 着手前のクリーンアップ範囲を確定するための材料。

行番号付き markdown link は当時時点 (commit `0cafa65`) の行を指す。後の修正でずれる可能性あり。

---

## 1. レビュー対象とアプローチ

| パッケージ | 行数 | レビュー内訳 |
|---|---|---|
| `katari-compiler` (Haskell) | 約 16k | frontend (Lexer / Parser / Identifier / AST) / typechecker (ConstraintGenerator / Solver / Zonker / NormalizedType / Exhaustive / ImportGraph / SemanticType) / backend (Lowering / IR / Schema / Query / Compile / Diagnostic / Prim) の 3 並列 |
| `katari-runtime` (TS) | 約 2.3k | engine 全体を 1 並列 |
| `katari-api-server` (TS) | 約 3k | services / storage / routes / ffi / recovery / metrics を 1 並列 |

**合計 5 並列** の Explore agent でファイル単位のチェックを実施。直接コードを再確認した critical 指摘:

- api-server `bin.ts` で `AgentService` 構築時に `ffi` 引数が渡されておらず、FFI executor が orphan
- runtime `event.ts` で `escalate` / `escalateAck` の型定義はあるが `runner.ts` の `translateExternal` に case 無し
- compiler `Identifier.hs` の ID 採番が global counter (`nextVariableId` / `nextTypeId` / `nextModuleId` / `nextRequestId` / `nextConstructorId`)

---

## 2. 未実装項目

### 2.1 既知 (ユーザ把握済み)

- FFI 読み込み機能 (delivery model 含む)
- CLI 本体 (`haskell/katari-cli/` は `app/` `src/` ともに空)
- LSP
- Syntax Highlight
- Package Manager

### 2.2 新規発見

| # | 場所 | 内容 |
|---|---|---|
| U-1 | [bin.ts:56](../typescript/packages/katari-api-server/src/bin.ts#L56) | `AgentService` 構築時に `ffi` 引数未注入。`HttpFFIExecutor` / `InProcessFFIExecutor` は実装済みだが orphan。CORE→FFI delegate イベントは `this.ffi === undefined` で hold |
| U-2 | [event.ts:51-60](../typescript/packages/katari-runtime/src/engine/event.ts#L51-L60) / [runner.ts:200-256](../typescript/packages/katari-runtime/src/engine/runner.ts#L200-L256) | `escalate` / `escalateAck` の型定義はあるが `translateExternal` に case 無し → silent drop |
| U-3 | [Query.hs:307](../haskell/katari-compiler/src/Katari/Query.hs#L307) | `hoverFromExpression` / `refFromExpression` で `_ -> Nothing` フォールスルー。`ExpressionHandle` / `ExpressionForBreak` / `ExpressionForNext` の case 無し → LSP hover/refs が常に miss |
| U-4 | [recovery.ts](../typescript/packages/katari-api-server/src/recovery.ts) / [storage/types.ts:142-150](../typescript/packages/katari-api-server/src/storage/types.ts#L142-L150) | `DiffRepo.append` は呼ばれているが replay path 無し。コメントが「Phase G で API surface だけ作って、replay は将来 revision」と明記 |
| U-5 | [IR.hs](../haskell/katari-compiler/src/Katari/IR.hs) | `schemaVersion = 1` 固定で bump policy / 進化戦略未定義 (skew 検知のみ) |

---

## 3. 設計の問題 (差分 build / agent 毎 IR への移行に向けた懸念)

### 3.1 Compiler 側

- **Identifier が monolithic な global counter で ID 採番** — [Identifier.hs:435-485](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L435). `identify :: Map Text (Module Parsed) -> ...` が全 module 一括処理で、1 module 編集 → 全 ID 振り直し。**差分 build の最大障壁**
- **`VariableData.variableQualifiedName = Nothing` for local var** — [Identifier.hs:151-170](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L151). 後段で module path 復元不可
- **`SemanticType` / `NormalizedType` に Generic / Aeson instance なし** — typecheck 結果の cache 化に必要
- **`ImportGraph` が cycle 検出のみ** — 依存グラフ保持・query API 無し。差分 build の "どの module を再 typecheck するか" 決定基盤が無い
- **`IRModule.entries :: Map QualifiedName BlockId` が module 単位** — [IR.hs:174-185](../haskell/katari-compiler/src/Katari/IR.hs#L174-L185) / [Lowering.hs:589-592](../haskell/katari-compiler/src/Katari/Lowering.hs#L589-L592). agent 毎 IR への移行で cross-agent 呼び出しが entries で解決できなくなる
- **`BlockId` / `ReqId` / `CtorId` が per-module 採番** — agent 毎 IR への移行で ID 衝突 / instability
- **`Common.parseQualifiedName` が末尾 `.` のみで split** — `a.b.c.name` を `module = "a.b.c"` と誤認 (nested module の取り扱い不完全)

### 3.2 Runtime / API server 側

- **FFI target endpoint が hard-coded** — [state.ts:46](../typescript/packages/katari-runtime/src/engine/state.ts#L46) `ffiTargetEndpoint`。`ExternalName` ごとに endpoint を carry する設計は「コメントのみ」で未実装
- **storage が module 単位で IR / SchemaBundle を持つ** — [storage/types.ts](../typescript/packages/katari-api-server/src/storage/types.ts) `ModuleRow`. agent 毎 IR への移行は schema migration を伴う
- **registry に qualifiedName / BlockId index が無い** — [registry.ts](../typescript/packages/katari-api-server/src/registry.ts) は `versionId → handle` のみ。lookup miss は runtime に問い合わせて初めて分かる
- **poison ロジック重複** — [agent-service.ts:635-672](../typescript/packages/katari-api-server/src/services/agent-service.ts#L635-L672) と [poison-handler.ts:27-61](../typescript/packages/katari-api-server/src/services/poison-handler.ts#L27-L61) でほぼ同一コード

### 3.3 Runtime architecture (Thread / IR 間の対応関係)

- **`UserThread` の責務過多** — statement 実行 / return キャッチ / agent boundary / API root の出口を兼ねている
- **agent boundary が型レベルで分離されていない** — IR の `UserBlock.kind = BlockKindAgent` enum と runtime の `UserThread.catchesReturn` boolean が dynamic に対応
- **`apiDelegations` / `apiDelegationSenders` / `ffiDelegations` の 3 マップに分散** — 外部 (sidecar / 別 Katari server / API) を区別する根拠なし
- **内部 agent call と inline call が同じ `SCall`** — agent boundary が runtime まで伝わらない

---

## 4. 潜在バグ (8 件)

| # | 場所 | 概要 |
|---|---|---|
| B-1 | [agent-service.ts:506-516](../typescript/packages/katari-api-server/src/services/agent-service.ts#L506-L516) | FFI invoke 失敗時、delegationId → agentId map が無く `running` の最初の agent を線形検索で cancel → 同 version で並行 FFI 中の無関係 agent が cancel される race |
| B-2 | [Lexer.hs:860-901](../haskell/katari-compiler/src/Katari/Lexer.hs#L860-L901) | virtual semicolon の bracket depth で `{` が抑止対象外 (CLAUDE.md で意図的設計と明示)。template `${...}` 内 expression mode の改行で破綻するか要再確認 |
| B-3 | [Lowering.hs:672-703](../haskell/katari-compiler/src/Katari/Lowering.hs#L672-L703) | handler body lower 後 `StatementExit` を無条件 append。全 path が break/next で抜ける handler では unreachable |
| B-4 | [recovery.ts:90-114](../typescript/packages/katari-api-server/src/recovery.ts#L90-L114) | offset pagination が並行 insert/delete に脆弱 (実用上はシングル process だが堅牢性低い) |
| B-5 | [Solver/Substitution.hs:197-227](../haskell/katari-compiler/src/Katari/Typechecker/Solver/Substitution.hs#L197-L227) | propagation で upper bound の `boundReason` 喪失 → diagnostic で複数 origin の競合情報が消える |
| B-6 | [Lowering.hs](../haskell/katari-compiler/src/Katari/Lowering.hs) 全体 | 再帰深さ上限なし。pathological AST (深い tuple / nested constructor pattern) で stack overflow 可能性。実用入力では問題ないが要 bench |
| B-7 | [Diagnostic.hs](../haskell/katari-compiler/src/Katari/Diagnostic.hs) / [Diagnostic/Render.hs](../haskell/katari-compiler/src/Katari/Diagnostic/Render.hs) | `span.start > span.end` の検証なし → underline 長が負になりうる |
| B-8 | [external.ts:54-62](../typescript/packages/katari-runtime/src/engine/external.ts) | external cancel が ack を待たず terminate 投擲のみ → 同一 delegationId への遅延 event 到着で routing 不定 |

---

## 5. 差分 build 設計に関する所見

### 5.1 ID 安定化の方針

連番採番の Identifier では差分 build 時に ID が変わるため、安定化が最初の課題:

- **(推奨) Hash-based ID**: `hash(modulePath, name, kind, occurrence)` で衝突実用ゼロ、cache key としても安全
- Per-module local counter + `(ModuleId, LocalId)` tuple — 読みやすいが ModuleId 自体の安定化が要る (これも結局 hash になる)

### 5.2 Typecheck 結果の cache 配置

**CLI 層が管理する**のが自然 (compiler は pure を保つ原則を維持)。

- compiler は per-module 入力 + 依存 module の SemanticType 等を取り、per-module ZonkResult chunk を返す pure 関数として再設計
- ファイル I/O や cache invalidation (ImportGraph 走査) は CLI 側
- 必要な作業: `SemanticType` / `NormalizedType` / `IdentifierResult` の per-module chunk を `Generic` + `aeson` で serialize 可能に / `ImportGraph` に `dependencies` / `dependents` を保持 / `compile` の signature を `identifyModule` / `typecheckModule` / `lowerModule` に分解

### 5.3 Cross-module dispatch

**「全 call を event 経由」は推奨しない** (prim を重くする必要なし)。代わりに dispatch target を 3 通りに区別:

| Call kind | Dispatch | コスト |
|---|---|---|
| same-module agent / inline block | `BlockId` 直 | 軽い |
| **cross-module agent** | `QualifiedName` outbound → registry が解決 → inbound | 重い (必要悪) |
| prim | 同期 in-process | 軽い |

これで agent 毎 IR の自然な延長になる。本 round の Thread/IR refactor (Phase 3) で `BlockAgent` を独立変項にして agent boundary を明確化することで、cross-module 化の土台を作る。

### 5.4 段階的移行ロードマップ

```
Phase 1  Thread/IR refactor (本 round) — agent boundary を runtime/IR で 1:1 化
Phase 2  ID 安定化 (hash-based)
Phase 3  Identifier を per-module 化
Phase 4  ImportGraph 拡充 + typecheck cache
Phase 5  Lowering を per-module 化、cross-module call を QualifiedName
Phase 6  agent 毎 IR / バージョニング
```

---

## 6. 次ステップ — 本 round の方向性

CLI 実装の前に以下を片付ける:

| 項目 | Phase | 備考 |
|---|---|---|
| 本ドキュメント追加 | 1 | review/2026-05-09-codebase-review.md |
| 小さな未実装 | 2 | FFI wire (U-1) / Query Handle・ForBreak (U-3) |
| Thread / IR refactor | 3 | AgentThread / Closure object / delegations 統合 / BlockAgent / core→core delegation。escalate (U-2) はこの中で解決 |
| 潜在バグ | 4 | 8 件すべて |
| DiffRepo 削除 | 5 | U-4 を確定撤退 (毎 step DB 書き込み運用へ) |

**CLI を最優先にする理由** (本 plan の前段で議論):
- 現状 compiler を実際に呼び出すパスが test 経由しかない
- 差分 build の「何を build と呼ぶか」「module 指定の単位」「cache 配置場所」が CLI 設計時に固まる → Phase 1 〜 Phase 4 (移行ロードマップ) の前提条件
- ただし CLI 着手前に Thread/IR refactor を済ませた方が、CLI が呼ぶ compile / runtime API が安定する

---

## 7. 本 round 対応 / 持ち越しの整理

### 本 round で対応

- ドキュメント (本ファイル)
- U-1 / U-3
- B-1 〜 B-8 全 8 件
- Thread / IR refactor (AgentThread / Closure object / delegations 統合 / BlockAgent / core→core delegation)
- DiffRepo 削除

### 持ち越し (差分 build フェーズ)

- Identifier の per-module 化 / hash-based ID
- `SemanticType` / `NormalizedType` の serialization
- `ImportGraph` の依存グラフ拡充
- `IRModule.entries` の agent 単位化 / cross-module dispatch 詳細
- `schemaVersion` (U-5) bump policy

### 持ち越し (FFI delivery model フェーズ)

- 外部モジュールをどう書き出してどう実行するか (HTTP sidecar / JS bundle / JS eval)
- per-ExternalName routing

### 持ち越し (個別タスク)

- CLI 本体
- LSP
- Syntax Highlight
- Package Manager
- 外部から closure を直接 call する機能 (本 round では意図的に除外)

### 撤退 (実装しない方針)

- recovery の diff log replay (毎 step DB 書き込み運用に確定)
