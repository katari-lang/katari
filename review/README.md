# KATARI コンパイラ Production Ready レビュー

レビュー日: 2026-05-06
対象: `haskell/katari-compiler/src/` (~15000 行)
レビュー観点: OSS としての公開前監査 (Production Ready 化)

## レポート一覧

| Step | レポート | 対象 |
| --- | --- | --- |
| 1 | [step1-architecture.md](step1-architecture.md) | 全体アーキテクチャとデータ構造 (Compile, AST, IR, Diagnostic, Id, SemanticType) |
| 2 | [step2-phase-separation.md](step2-phase-separation.md) | 各 phase の関心の分離 (Lexer → Parser → Identifier → ... → Lowering) |
| 3 | [step3-libraries.md](step3-libraries.md) | 既存ライブラリの活用と車輪の再発明 |
| 4 | [step4-production-ready.md](step4-production-ready.md) | Panic 経路 / パフォーマンス / テスト / ドキュメント |
| 5 | [step5-conventions.md](step5-conventions.md) | CLAUDE.md コーディング規約の遵守度 |

## 全体結論

KATARI コンパイラは **OSS Production Ready 化に show-stopper はない**。設計の骨格 (Trees-that-Grow, JSON IR, 統一 Diagnostic, pure pipeline) は OSS としても誇れる水準。

主な改善は局所的な修正で対応可能:
- API surface の整理 (ID 型再エクスポートの解消、Lexer の export list)
- 3 つの「車輪の再発明」削除 (Tarjan SCC, `(!?)`, `nub`)
- Panic 経路の統一 (bare `error` を `Internal.error` に)
- 命名規則の機械的修正 (`params` → `parameters`, `ctx` → `context` 等)

## 優先度マトリクス (5 step を統合)

### A. 修正コスト「半日」級の必須項目 (OSS 公開前にやるべき)

1. **`Identifier` の ID 型 re-export を削除** ([Step 2](step2-phase-separation.md))
2. **`Lexer` に explicit export list 追加** ([Step 2](step2-phase-separation.md))
3. **bare `error` (Lowering:501, Identifier:638) を `Internal.error` 化** ([Step 4](step4-production-ready.md))
4. **`ImportGraph` の Tarjan を `Data.Graph.stronglyConnComp` に置換** ([Step 3](step3-libraries.md))
5. **`Render.hs` の `(!?)` を `Safe.atMay` に置換** ([Step 3](step3-libraries.md))
6. **`Substitution.hs` の `nub` を `Set` 経由に置換** ([Step 3](step3-libraries.md))
7. **cabal の未使用 dep (`vector`, `bytestring`, `scientific`) 削除** ([Step 3](step3-libraries.md))
8. **命名規則違反の機械的 rename** (`params`/`ctx`/`zr` 等) ([Step 5](step5-conventions.md))
9. **`CompileResult` の不必要な `Maybe` を削除** (`identifierResult`/`solverResult`/`zonkResult`) ([Step 1](step1-architecture.md))

### B. 修正コスト「1-2 日」級の重要項目

10. **エラー返却スタイルの統一** (全部 tuple style) ([Step 2](step2-phase-separation.md))
11. **Golden test スイート追加** (IR JSON の binary compatibility 保護) ([Step 4](step4-production-ready.md))
12. **README / CHANGELOG / CONTRIBUTING 整備** ([Step 4](step4-production-ready.md))
13. **`prettyprinter` 採用で Diagnostic.Render を再実装** ([Step 3](step3-libraries.md))
14. **IR の `Block` フィールド名統一** (BlockUser.body vs BlockMatch.matchBlock) ([Step 1](step1-architecture.md))
15. **`Zonker` の `IdentifierResult` 再格納を解消** (Lowering に IdentifierResult を直接渡す) ([Step 2](step2-phase-separation.md))

### C. 修正コスト「1 週間+」級の品質向上

16. **Property test スイート (`hedgehog` 統合)** ([Step 4](step4-production-ready.md))
17. **Internal panic を `Diagnostic K9999` 化する fail-soft 経路整備** ([Step 4](step4-production-ready.md))
18. **`QualifiedName` / `LiteralValue` の AST/IR 二重定義の整理** ([Step 1](step1-architecture.md))
19. **`BlockCtor`/`CtorId`/`ReqId` を `BlockConstructor`/`ConstructorId`/`RequestId` にリネーム** (IR breaking change) ([Step 5](step5-conventions.md))

## 設計上の美点 (公開時にアピール可能)

1. **完全 pure な単一エントリ** `compile :: CompileInput -> CompileResult` ([Step 1](step1-architecture.md))
2. **Trees-that-Grow を closed type family + `NameRefKind` で実用化**: 型レベルで「handler target が req でない」「match pattern が data ctor でない」を reject ([Step 1](step1-architecture.md))
3. **5+4 ID 体系と `QualifiedName` 境界の二層分離**: IR 内部 dispatch ID と FFI 公開名を意図的に分離 ([Step 1](step1-architecture.md))
4. **Forward-only DAG**: 全 phase が strictly acyclic、Parser に型情報依存ゼロ ([Step 2](step2-phase-separation.md))
5. **Solver の sub-module 分割**: 1.4k 行の solver が `Decompose`/`Branch`/`Substitution`/`Request`/`Internal` で適切に分割 ([Step 2](step2-phase-separation.md))
6. **安定 4 桁 diagnostic code (K####)**: phase レンジで分割、LSP `relatedInformation` / `codeAction` への直接マップ ([Step 1](step1-architecture.md))
7. **`\case` 144 件**: コーディング規約への高い遵守度 ([Step 5](step5-conventions.md))

## OSS 公開ロードマップ案

### Phase 1 (3 日): 最低限の OSS 公開準備
- A 群 9 項目を全て実施
- README.md / CHANGELOG.md (diagnostic code registry 含む) / CONTRIBUTING.md / LICENSE 整備
- Golden test 5-10 個

### Phase 2 (追加 1 週間): Production-grade OSS
- B 群実施 (特に `prettyprinter` 化と Property test)
- Haddock の `>>>` 例追加
- CI で coverage 計測 + Codecov 連携

### Phase 3 (継続的): 大規模リファクタリング
- C 群を semver の major version bump 時に実施
