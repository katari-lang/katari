# katari-compiler

KATARI 言語の純粋関数コンパイラ。Source text の `Map ModuleName Text` を入力に、
JSON 化可能な IR と JSON Schema, 統一 Diagnostic を出力する。File IO は呼び出し側
(別パッケージ予定の `katari-project` / CLI / LSP / playground) の責任。

## 統一エントリ

```haskell
import Katari.Compile (compile, CompileInput (..), CompileResult (..))

compile :: CompileInput -> CompileResult
```

`CompileResult` は以下のフィールドを持つ:

| フィールド          | 型                          | 説明                                                |
| ------------------- | --------------------------- | --------------------------------------------------- |
| `irModule`          | `Maybe IRModule`            | error diagnostic があれば `Nothing`                 |
| `schemaBundle`      | `Maybe SchemaBundle`        | 同上                                                |
| `diagnostics`       | `[Diagnostic]`              | 全 phase のエラー・警告                             |
| `identifierResult`  | `Maybe IdentifierResult`    | LSP / CLI 向け名前解決テーブル                      |
| `solverResult`      | `Maybe SolverResult`        | 型制約解決結果                                      |
| `zonkResult`        | `Maybe ZonkResult`          | `Katari.Query` の入力                               |

## モジュール構造

```
Katari.Compile               -- 統一エントリ. 全 phase を直列に呼び出し、
                                Diagnostic / IR / Schema をまとめて返す.

Katari.Lexer                 -- Char stream → [WithPos Token]. 仮想セミコロン挿入,
                                テンプレリテラル状態管理.
Katari.Parser                -- Token stream → Module Parsed. megaparsec カスタム
                                ストリーム. break/next 文脈を ReaderT で透過.

Katari.AST                   -- Trees-that-Grow phase 化 AST. Phase = Parsed |
                                Identified | Constrained | Zonked. NameMeta /
                                ExprType / PatType の type family で phase 別 metadata.
                                SymbolKind に RequestRef / ConstructorRef を含む 6 slot
                                (handler / match constructor pattern を型レベル分離).
Katari.AST.Identifiers       -- VariableId / TypeId / ModuleId / RequestId /
                                ConstructorId と QualifiedName. Identifier pass で発行.

Katari.Typechecker.Identifier      -- 名前解決 (5 namespace: variable / type / module
                                      / request / constructor + label). 未解決名や
                                      kind 不一致 (handler が agent / pattern が req
                                      など) を IdentifierError で reject.
Katari.Typechecker.SemanticType    -- 型表現 (SemanticType, SemanticEffect).
                                      Unresolved / Resolved の 2 phase. uniplate で walk.
Katari.Typechecker.NormalizedType  -- 正規化型 (lattice 演算 unionNT / intersectNT,
                                      subtype 判定).
Katari.Typechecker.ConstraintGenerator -- AST Identified → AST Constrained + 制約集合
                                          (subtype / effect).
Katari.Typechecker.Solver          -- 制約解決. Decompose / Branch / Substitution /
                                      Effect の sub-module で構造分解 → 分岐 →
                                      代入決定 → effect 集約.
Katari.Typechecker.Zonker          -- 解決済み代入を Constrained AST に焼き付け
                                      Zonked AST へ (型情報を確定).

Katari.Lowering              -- AST Zonked → IRModule. ReaderT (LowerEnv) State
                                (LowerState). let / param の pattern destructuring を
                                tuple_get / get_field prim で再帰的に展開. match arm
                                の pattern は MatchPattern 木として直訳 (runtime が
                                walk). closure capture は runtime の scope inheritance
                                に委譲 (IR captures は予約のみ).
Katari.IR                    -- IR データ型 + JSON serialization. Block sum は
                                BlockUser / Prim / Request {reqId} / External
                                {externalName} / Ctor {ctorId}. BlockKind enum で
                                UserBlock の役割を表現. MatchArm は再帰的 MatchPattern
                                (MPAny / MPVariable / MPLiteral / MPConstructor / MPTuple).
                                IRModule.entries :: Map QualifiedName BlockId を FFI
                                境界の唯一の SSoT として持つ. ToJSON / FromJSON は
                                genericToJSON で自動.
Katari.Schema                -- ZonkResult → SchemaBundle. AI tool calling 用 JSON
                                Schema (Draft 2020-12 サブセット). Bundle は flat:
                                agentSchemas / requestSchemas / externalSchemas /
                                dataSchemas (constructor as callable) / dataDefs
                                ($defs) すべて Map QualifiedName _ で keyed.
                                Annotation を description として埋め込む.

Katari.Diagnostic            -- 統一 Diagnostic 型 (severity, code "K####", span,
                                message, notes, hints). 各 phase の error 型から
                                toDiagnostic で変換. helpers: filterAtLeast /
                                sortBySpan / groupByFilePath.
Katari.Diagnostic.Render     -- CLI 向けレンダリング. renderDiagnostic (snippet 付き)
                                / renderDiagnosticPlain. source text dependency を
                                core diagnostic 型から分離.

Katari.Query                 -- LSP / CLI 向け query layer. ZonkResult を入力に
                                position-based lookup (lookupAtPosition) / occurrence
                                index (buildOccurrenceIndex) / find-references /
                                go-to-definition を提供. Position は code-point 単位
                                (UTF-16 換算は LSP layer が担当).
```

## パイプライン

```
Map ModuleName Text
  → parse              [Diagnostic] (Lexer / Parser エラー K0001-K0099)
  → identify           [Diagnostic] (Identifier エラー K0100-K0199)
  → constraint-gen
  → solve              [Diagnostic] (Solver / 型エラー K0200-K0299)
  → zonk
  → ┬ lower            [Diagnostic] (Lowering エラー K0300-K0399) → IRModule
    └ buildSchemas → SchemaBundle
```

Lowering と Schema は `ZonkResult` を共有する独立並列 stage (Schema は IR に依存しない)。

## ビルド・テスト

```sh
stack build katari-compiler
stack test katari-compiler
stack haddock katari-compiler --no-haddock-deps
```

## 設計上の方針

- **Pure**: file IO / katari.toml 解析は別パッケージ (`katari-project` 予定) の責任。
  本パッケージは LSP の unsaved buffer や playground 等から `Map ModuleName Text` を
  直接受け取って動く。
- **Trees-that-Grow**: phase 推移は payload を素通しする identity 変換になり
  `passThroughX` 系 boilerplate を排除。
- **JSON IR**: binary serialization は採用せず、IR は JSON のまま runtime に渡す。
  ToJSON / FromJSON は `genericToJSON` で自動生成。
- **Two-layer ID discipline**: IR 内部は `BlockId` / `VarId` / `ReqId` / `CtorId` で dispatch、
  外部 (FFI / JS) は `QualifiedName` で名前解決。`IRModule.entries :: Map QualifiedName BlockId`
  が境界の唯一の翻訳テーブル。逆引きは runtime が load 時に 1 周走査して構築。
- **Match に runtime walker を委譲**: `MatchPattern` を再帰的に保持して runtime が値と pattern を
  walk。Lowering は AST → IR を直訳するだけで、cascade SMatch 構築は不要。任意深度ネストや
  same-tag arm overlap も自動対応。
- **Annotation は AST 側に温存**: `SemanticType` には annotation を入れない
  (subtyping / normalization のノイズになるため)。Schema 生成時に AST を walk して
  zip で組み合わせる。
- **統一 Diagnostic**: 各 phase が独自エラー型を返す現状維持に加え、`toDiagnostic`
  converter で `Diagnostic` (code, severity, span, message, notes, hints) に集約。
  CLI / LSP / 新 TS runtime の結合点で扱いやすい。
- **型名プレフィックス付きコンストラクタ**: 全直和型のコンストラクタに型名プレフィックスを付ける
  (`StatementCall` / `MatchPatternAny` / `CallTargetBlock` 等)。JSON tag はコンストラクタ名を
  そのまま使う (PascalCase: `"StatementCall"` / `"MatchPatternAny"` 等)。`lowerHead` / `stripXXPrefix`
  は不使用 — camelCase 変換は `foo` と `Foo` を runtime で区別できなくなるため。
- **GADTs 構文**: 全直和型は `data T where ...` 形式を使う。
- **parse / lex プレフィックス**: `Parser a` を返す関数は `parse` プレフィックス、
  `Lexer a` を返す関数は `lex` プレフィックス必須。
- **IRModule.metadata**: `schemaVersion :: Int` で runtime との version skew を検知。現行 = 1。
- **LSP query layer は CompileResult 外**: `buildOccurrenceIndex` は `CompileResult` に含めず
  LSP layer が明示的に呼ぶ (compile を軽量に保つ)。
