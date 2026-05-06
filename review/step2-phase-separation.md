# Step 2: 各フェーズの関心の分離の検証

## 調査範囲

| Phase | 行数 | エントリ |
| --- | --- | --- |
| Lexer | 1028 | `lex :: FilePath -> Text -> (KatariTokenStream, [LexerError])` |
| Parser | 1810 | `parse :: FilePath -> KatariTokenStream -> (Module Parsed, [ParseError])` |
| Identifier | 2111 | `identify :: Map Text (Module Parsed) -> (IdentifierResult, [IdentifierError])` |
| ConstraintGenerator | 1624 | `generateConstraints :: IdentifierResult -> (ConstraintGenResult, [ConstraintError])` |
| Solver | 340 + 1108 (sub) | `solve :: ConstraintGenResult -> SolverResult` |
| Zonker | 777 | `zonk :: IdentifierResult -> ConstraintGenResult -> SolverResult -> ZonkResult` |
| Lowering | 1417 | `lowerProgram :: Text -> ZonkResult -> (IRModule, [LoweringError])` |

## 美しい設計点

### 1. 教科書的に綺麗なエントリシグネチャ

各 phase は単一エントリ + 入力は前段の result(s) のみ。Compile.hs は単に直線的に繋ぐだけ。テスト容易性 (各 phase が独立に unit test 可能) も担保される。

### 2. 強制された forward-only DAG

import グラフを確認した結果、**逆向き依存ゼロ**:

```
Lexer       ← Diagnostic, SourceSpan
Parser      ← AST, Diagnostic, Lexer, SourceSpan
Identifier  ← AST, Diagnostic, Id, Internal, SourceSpan, Typechecker.ImportGraph
ConstraintGenerator ← AST, Diagnostic, SemanticType, SourceSpan, Typechecker.Identifier
Solver      ← Diagnostic, SemanticType, SourceSpan, Typechecker.{ConstraintGenerator, Identifier(RequestId), NormalizedType, Solver.*}
Zonker      ← AST, Diagnostic, SemanticType, SourceSpan, Typechecker.{ConstraintGenerator, Identifier, NormalizedType, Solver}
Lowering    ← AST, Diagnostic, IR, Internal, SourceSpan, Typechecker.{Identifier(VariableId), Zonker}
```

特に **Parser が型情報に一切依存していない** のは確認済み (Parser.hs 内に `SemanticType` / `Identifier` 等の言及はコメント / docstring のみ)。Identifier も ConstraintGenerator を import せず、ConstraintGen も Solver を import しない。コンパイラとして当たり前のはずだが、実際にはここが汚れる事例が多いので価値がある。

### 3. Solver の sub-module 分割

`Solver/` 配下が機能別に分割されており、見通しが良い:

- `Solver.Internal` — 共有型 (import cycle 回避)
- `Solver.Decompose` — `t1 <: t2` の構造的分解
- `Solver.Branch` — 行き詰まり時の分岐 (`α <: composite` を narrow vs never/unknown に展開)
- `Solver.Substitution` — 代入 / bound 計算
- `Solver.Request` — request constraint を別ロジックで解決

1.4k 行の solver にはちょうど良い粒度。

### 4. Solver-Zonker 境界の defensive 設計

Zonker.hs:11-16 のコメント:
> Solver の出力は **total** : Solver bug (lookup miss) は `ZonkErrorMissingTypeVar` で検知し、`SemanticTypeUnknown` にフォールバック

`totaliseTypes` ([Solver.hs:279-282](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L279-L282)) で全 TypeVariableId に entry を強制する契約と、それでも漏れた場合の Zonker 側の検知。Production の compiler bug に対する gracefulness が考慮されている。

### 5. Identifier の Namespace モデル

[Identifier.hs:97-124](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L97-L124) の `SymbolEntry` は 5 slot (variable / type / module / request / constructor) を 1 名前に持たせる。`data Foo()` が variable + type + constructor の 3 slot を同時占有するように、Katari 言語の name resolution semantics を無理なく表現できている。

特に「variable + module 共存禁止」(line 105-107) という invariant は、`name.foo` の意味が field access か qualified module access かを **構文的曖昧性なし** に決定するための工夫として優れている。

## 懸念点 / 改善案

### 【高】`Identifier` が `Katari.Id` の ID 型を再エクスポート ([Identifier.hs:22-44](../haskell/katari-compiler/src/Katari/Typechecker/Identifier.hs#L22-L44))

Identifier 自身のコメント (line 70-77) に「**re-exported below for backward compatibility with existing call sites**」と明記されている。下流の Solver / Zonker / Lowering は本来 `Katari.Id` から ID を import すべきなのに、Identifier 経由で import している:

```haskell
-- Solver.hs:75
import Katari.Typechecker.Identifier (RequestId)
-- Zonker.hs:55-67
import Katari.Typechecker.Identifier (...VariableId, TypeId, ModuleId, RequestId, ConstructorId)
-- Lowering.hs:32-33
import Katari.Typechecker.Identifier (VariableId)
import Katari.Typechecker.Identifier qualified as Identifier
```

**これは leaky abstraction。** ID 型は phase 不変な値オブジェクトであり、Identifier phase に帰属しない。

**推奨対応** (低リスク):
1. `Identifier.hs` の export list から `VariableId(..) / TypeId(..) / ModuleId(..) / RequestId(..) / ConstructorId(..) / QualifiedName(..) / renderQualifiedName` を削除
2. 下流 3 モジュールの import を `Katari.Id` 経由に書き換え
3. 結果として下流の各 phase は「ID 型は phase 横断値」「Identifier は ID 発行責任のみ」という意味論を獲得

この修正は OSS としての公開前にやっておくべき。後から API を狭めるのは breaking change。

### 【高】`Lexer` に export list がない ([Lexer.hs:1](../haskell/katari-compiler/src/Katari/Lexer.hs#L1))

```haskell
module Katari.Lexer where
```

つまり `lex` / `initialLexerState` / `lexGetTopContext` / `lexPushContext` / `lexAllTokens` / `lexNumber` / `lexIdentifierOrKeyword` / `lexTemplateBodyToken` 等、**全ての内部ヘルパが public**。`katari-compiler.cabal` の `exposed-modules` に `Katari.Lexer` が入っているため、ライブラリ利用者は何でも import できる。

**問題**: 内部実装を変更するたびに breaking change の可能性。OSS の semver 管理が成立しない。

**推奨対応**:
```haskell
module Katari.Lexer
  ( -- * Public API
    KatariToken (..),
    Keyword (..),
    Punctuation (..),
    Operator (..),
    KatariTokenStream,
    LexerError (..),
    toDiagnostic,
    lex,
  )
where
```

`Parser.hs` は既にこのスタイル ([Parser.hs:11-16](../haskell/katari-compiler/src/Katari/Parser.hs#L11-L16))。Lexer も合わせるべき。

### 【中】エラー返却スタイルの不整合

| Phase | スタイル |
| --- | --- |
| `parse` | `(result, [errors])` tuple |
| `identify` | `(result, [errors])` tuple |
| `generateConstraints` | `(result, [errors])` tuple |
| `solve` | `result` (errors in `solverErrors` field) |
| `zonk` | `result` (errors in `zonkErrors` field) |
| `lowerProgram` | `(result, [errors])` tuple |

混在している。Compile.hs での扱いも対応して 2 種類:

```haskell
(parsed, parseDiags) = parseSources input.sources
solverDiags = map Solver.toDiagnostic solverResult_.solverErrors
```

**推奨**: 全部 tuple style で統一 (Haskell では一般的)。あるいは全部 record style (errors inline) で統一。前者が無難。

### 【中】`Zonker` が `IdentifierResult` のフィールドを `ZonkResult` に再格納

[Zonker.hs:91-99](../haskell/katari-compiler/src/Katari/Typechecker/Zonker.hs#L91-L99):

```haskell
data ZonkResult = ZonkResult
  { ...
    -- Passthroughs from 'IdentifierResult' so 'Katari.Lowering' and 'Katari.Schema'
    -- can resolve qualified names ... without re-threading 'IdentifierResult'.
    zonkedVariables :: Map VariableId VariableData,
    zonkedTypes :: Map TypeId TypeData,
    zonkedRequests :: Map RequestId RequestData,
    zonkedConstructors :: Map ConstructorId ConstructorData,
    zonkedRequestByVariable :: Map VariableId RequestId,
    zonkedConstructorByVariable :: Map VariableId ConstructorId,
    ...
  }
```

`IdentifierResult` の中身を ZonkResult が抱え直している。理由は妥当 (down-stream の引数を減らしたい) だが副作用として:

- データの二重保持 (メモリ的には負の最適化)
- `ConstructorData` 等を変更すると Zonker の API 契約まで変わる
- "Zonker は何のためのモジュールか" がぼやける (型解決+symbol table中継?)

**代案案 A**: `Lowering` / `Schema` に `IdentifierResult` も渡す (素直)

```haskell
lowerProgram :: Text -> IdentifierResult -> ZonkResult -> (IRModule, [LoweringError])
```

実際 Zonker は既に両方を受け取っているので、この変更は Compile.hs の 1 行追加で済む。

**代案案 B**: 共通の `SymbolTable` 型を導入し、Identifier/Zonker/Lowering 全員がそれを共有。
今 `IdentifierResult` が事実上 SymbolTable + ASTs の二役なので、分離して両方の phase で同じ SymbolTable を使う。やや大きな refactor。

短期は A、中期は B が望ましい。

### 【中】`ConstraintGenResult.nextTypeVariableId / nextRequestVariableId` の生 `Int` 漏れ

[ConstraintGenerator.hs:200-207](../haskell/katari-compiler/src/Katari/Typechecker/ConstraintGenerator.hs#L200-L207):

```haskell
data ConstraintGenResult = ConstraintGenResult
  { constrainedModules :: Map ModuleId (Module Constrained),
    typeEnvironment :: TypeEnvironment,
    constraints :: Set Constraint,
    nextTypeVariableId :: Int,    -- 内部カウンタが public surface に流出
    nextRequestVariableId :: Int  -- 同上
  }
```

Solver はこれを使って branching 中に fresh var を発行する ([Solver.hs:97](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L97))。
**問題**: 「ConstraintGenerator 内部カウンタの最終値」が API 契約として固定化される。

**推奨**:
```haskell
data VariableSupply = VariableSupply
  { typeVarSupply :: Int,
    requestVarSupply :: Int
  }
```
として 1 フィールド `variableSupply :: VariableSupply` で渡す。Solver は内部で `freshTypeVar`/`freshRequestVar` 関数を持つ。意図が明確になる。

### 【中】`solveRequestWorklist` の未使用引数 ([Solver.hs:265-269](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L265-L269))

```haskell
solveRequestWorklist :: Int -> Set Constraint -> (Map RequestVariableId (Set RequestId), [SolverError])
solveRequestWorklist _ = Request.solveRequestConstraints
```

第 1 引数 (`Int`、`nextRequestVariableId`) を破棄。シグネチャに残す理由がない。削除すべき。

### 【低】`synthesisedReason` の `dummySpan` フォールバック ([Solver.hs:236-249](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L236-L249))

```haskell
dummySpan = SrcSpan { filePath = "", start = Position {line = 0, column = 0}, end = ... }
```

`(0,0)-(0,0)` で空 file path のスパンが diagnostic として出ると、LSP で goto-definition 機能を破壊する可能性。

**推奨**: `Diagnostic.span` を `Maybe SourceSpan` に変えて、span がない場合は `notes` 側にメッセージを寄せる。または、最低 1 つの constraint がある場合のみ発生する経路にする (構造的に保証)。

### 【低】Solver の "totalise" による silent 補完

`totaliseTypes` / `totaliseRequests` ([Solver.hs:279-290](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L279-L290)) は missing TypeVariableId を `NormalizedTypeUnknown` で埋める。これは defensive design として正しいが **silent**。

**推奨**: missing が発生した場合、`SeverityWarning` の Diagnostic を発行する (内部 invariant 違反を OSS 利用者に観測可能にする)。

## 全体評価

各 phase の **関心の分離は教科書通り** に守られている。逆向き依存ゼロ、Parser に型情報なし、Solver の sub-module 分割が適切。これは OSS として誇れる水準。

主な改善は「**API surface の整理**」に集約される:
- ID 型の再 export 削除 (Identifier → Id 経由に統一)
- Lexer の export list 整備
- エラー返却スタイル統一
- ConstraintGenResult の生カウンタ封じ込め
- `IdentifierResult` の二重保持解消

これらは breaking change を許容できる「OSS 公開前」の今がやり時。

## 後段で追跡すべき未解決事項

- [ ] `Internal.error` / `internalErrorNoSpan` の使用箇所一覧 (Step 4 で実施)
- [ ] Lexer の virtual semicolon 挿入の正しさ (実機で確認するか tests に委ねるか)
- [ ] `Zonker` が `IdentifierResult` を再パッケージしている分の AST walk コスト (Step 4 のパフォーマンス節で評価)
