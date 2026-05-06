# Step 5: コーディング規約の遵守の監査

CLAUDE.md「Haskell コーディング規約」(規約 1-4) に対する実装の遵守度を監査。

## 規約 1: 関数羅列パターンマッチを避ける (`\case` を使う)

### 結果: ほぼ完璧に遵守 ✓

`\case` の使用箇所: **144 件**。phase ごとの walker / converter / 多様な enum マッチが全て `\case` 化されている。

具体例:
- [AST.hs:1042](../haskell/katari-compiler/src/Katari/AST.hs#L1042) `retagSyntacticType = \case`
- [Lowering.hs:101](../haskell/katari-compiler/src/Katari/Lowering.hs#L101) `binaryOpPrim = \case`
- [Identifier.hs:..., Parser.hs:..., Solver.hs:301](../haskell/katari-compiler/src/Katari/Typechecker/Solver.hs#L301) など

### 違反 (なし)

機械的検出では複数の hits が出たが、いずれも import ブロック / standalone deriving / 別の関数の隣接定義で、関数羅列パターンマッチ違反ではない。

`Diagnostic.hs:131-151` の `diagnosticError` / `diagnosticWarning` は別関数。`AST.hs` の `retag*` 4 関数も別関数。✓

## 規約 2: 便利構文の積極利用

### 結果: 全て活用 ✓

- `LambdaCase`: 144 件 (規約 1 経由)
- `RecordWildCards`: `EqPhase` 制約での使用 / [AST.hs:1043](../haskell/katari-compiler/src/Katari/AST.hs#L1043) の retag walker など多数
- ガード: `IR.hs:154-156` の `renderQualifiedName` など
- `where` バインディング: **全 26 モジュールで使用** (集計済み: AST 85, Identifier 15, Parser 18, Lexer 22 ...)

`OverloadedStrings`, `NoFieldSelectors`, `OverloadedRecordDot`, `StrictData` 等も `default-extensions` で有効化済み ([katari-compiler.cabal:48-65](../haskell/katari-compiler/katari-compiler.cabal))。

## 規約 3: データ定義はそのまま

### 結果: 遵守 ✓

`data` / `newtype` 宣言は通例の Haskell スタイル。型クラスインスタンスは genericToJSON / genericParseJSON で自動生成、もしくは standalone deriving で `EqPhase` / `ShowPhase` 制約付き。手動 instance 実装は最小限。

## 規約 4: 命名規則

### 4.1 型名・コンストラクタ名 (フルワード + 型名プレフィックス)

#### 結果: 遵守 ✓

- `TokenIdentifier`, `KeywordFor`, `PunctuationLeftBrace`, `BinaryOperatorAdd`, `ExpressionLiteral`: 全て規約通り
- `BlockUser`, `BlockPrim`, `BlockRequest`, `BlockExternal`, `BlockCtor`, `BlockMatch`, `BlockFor`, `BlockHandle`, `BlockTuple`, `BlockArray` ([IR.hs:244-285](../haskell/katari-compiler/src/Katari/IR.hs#L244-L285)): 規約通り
- `StatementCall`, `StatementMakeClosure`, `StatementLoadLiteral`, ... : 規約通り
- `MatchPatternAny`, `MatchPatternVariable`, ... : 規約通り

ただし **`BlockCtor` の "Ctor"** はフルワード「Constructor」の略。
- 元の規約: 「フルワードを使う。略語禁止。」
- 実態: `data DataParameter`、`type ConstructorId`、`MatchPatternConstructor` のように **フルワード "Constructor" は別箇所で使われている**
- BlockCtor のみ短縮形。**統一性違反**。

**推奨**: `BlockCtor` → `BlockConstructor` (とそれに連動する `CtorId` → `ConstructorIdIR` あるいは IR namespace 内では `ConstructorId` で良い)。

`ReqId` / `CtorId` も同様 (Request/Constructor の略)。CLAUDE.md には「`ReqId` — `BlockRequest` 内部の dispatch id」と書いてあるが、これも略語。フルワード ✗。

#### 軽微: GADTs vs `data ... = ... | ...`

CLAUDE.md は「直和型: GADTs 構文を使う」と規定。実態:

- AST.hs / IR.hs / Identifier.hs etc. の主要 sum 型は **GADTs 構文** を使用 ✓
- ただし [SemanticType.hs:64](../haskell/katari-compiler/src/Katari/SemanticType.hs#L64) の `data SemanticType phase where` も GADTs。良い。
- [SourceSpan.hs:6](../haskell/katari-compiler/src/Katari/SourceSpan.hs#L6) の `data Position` は record syntax で GADTs ではない (record 用。直和ではないので OK)。
- [Diagnostic.hs:57](../haskell/katari-compiler/src/Katari/Diagnostic.hs#L57) の `Severity` は GADTs ✓

遵守。

### 4.2 レコードフィールド (フルワード)

#### 結果: 部分的違反 ⚠

CLAUDE.md: 「省略形は使わない (`params` ✗, `args` ✗, `op` ✗, `ins` ✗)」

#### 違反箇所

##### `params` 等の使用 ⚠

- [Schema.hs:445](../haskell/katari-compiler/src/Katari/Schema.hs#L445): `dataParamObject dataDefs fieldTypes params = ...`
- [ConstraintGenerator.hs:664](../haskell/katari-compiler/src/Katari/Typechecker/ConstraintGenerator.hs#L664): `walkParameterListForSignature params = do`
- [Exhaustive.hs:233](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L233): `Just (SemanticTypeFunction params _ _) -> ...`
- [Exhaustive.hs:291](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L291): `Just (SemanticTypeFunction params _ _) -> ...`
- [Exhaustive.hs:456](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L456): `walkAgentBody zr maybeVarId params block = ...`
- [Exhaustive.hs:464](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L464): `concatMap (checkParam zr paramTypes) params`

修正: `params` → `parameters`。これは `SemanticTypeFunction` の field 名は既に `parameterTypes` (フルワード) なので、destructure / 局所束縛だけが略語化している。

##### `ctx` の使用 ⚠

[Exhaustive.hs](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs) で **6+ 箇所**:

```haskell
headColumnType ctx = case ctx.columnTypes of ...      -- L133
useful ctx matrix@(PatMatrix rows) testRow = ...      -- L145
specializeCtx tag colType ctx = ...                   -- L214
defaultCtx ctx = ctx {columnTypes = drop 1 ctx.columnTypes} -- L221
ctx = TypeCtx {columnTypes = [subjectType], ...}      -- L386, L417
```

修正: `ctx` → `context`。

[ConstraintGenerator.hs:1606, 1618](../haskell/katari-compiler/src/Katari/Typechecker/ConstraintGenerator.hs#L1606) でも同パターン:
```haskell
generateConstraints result = case runState (runReaderT action ctx) initialState of
  ...
  ctx = initialContext result.identifiedTypes ...
```

修正同上。

##### `zr` (zonkResult) の使用 ⚠

[Exhaustive.hs:386, 456, 464](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L386):
```haskell
ctx = TypeCtx {columnTypes = [subjectType], zonkResult = zr}
walkAgentBody zr maybeVarId params block = ...
```

`zr` は局所束縛で「the zonkResult」を表す。フルワードなら `zonkResult`。**違反**。

##### その他: `colType`, `dp`, `kw` の略 (要確認)

`colType` ([Exhaustive.hs:214](../haskell/katari-compiler/src/Katari/Typechecker/Exhaustive.hs#L214)) は `columnType` の略。違反。

[Schema.hs:449](../haskell/katari-compiler/src/Katari/Schema.hs#L449) `| dp <- params,` の `dp` は `dataParameter` の略。違反。

### 4.3 Parser/Lexer 関数のプレフィックス

#### 規約: Parser を返す関数は `parse`、Lexer 内の関数は `lex`

#### Parser.hs ✓ ほぼ遵守 (helper のみ違反)

`parse` プレフィックスでない関数:
- `extractReason` ([Parser.hs:???](../haskell/katari-compiler/src/Katari/Parser.hs)) — diagnostic 補助関数 (Parser を返さない)。**規約上は OK**。
- `retagParsedNameRef`, `expressionOperatorTable`, `makeBinaryOperatorExpression`, `applyPostfixOperation` — いずれも Parser を返さない pure utility。**規約上は OK**。

判定: 厳密には「Parser を返す関数」のみ規約対象。これらは違反ではない。

#### Lexer.hs ⚠ 軽微違反

「Lexer 内の関数」は規約上もっと広い (return 型の制約なし)。`lex` プレフィックスのない top-level 関数:

- `classifySurrogate :: Int -> SurrogateClass`
- `mkSourcePos :: FilePath -> Position -> SourcePos`
- `showKeyword`, `showPunctuation`, `showOperator`, `showToken`

このうち:
- `mkSourcePos`, `show*` は generic な builder/render utility なので **`lex` プレフィックスは合わない**。これらは `Lexer` モジュール内に置くこと自体が議論の余地あり (Show インスタンスを派生するか、別モジュールに切り出すか)。
- `classifySurrogate` は Lexer 専用ロジック。**`lexClassifySurrogate` にリネーム推奨**。

### 4.4 ローカル変数の命名

#### 規約: 抽象的なコードのみ一文字可。具体的なドメイン値はフルネーム。

#### 違反: `\s -> s {...}` の State update

[Lowering.hs:202, 210, 224, 231, 246, 255, 268, 273, 457](../haskell/katari-compiler/src/Katari/Lowering.hs#L202) などで `\s -> s {field = ...}` という Lambda が頻出。`s` は `LowerState` (具体的なドメイン値)。

```haskell
modify (\s -> s {lsNextBlockId = s.lsNextBlockId + 1})
```

**規約厳守なら**:
```haskell
modify (\state -> state {lsNextBlockId = state.lsNextBlockId + 1})
```

Haskell idiom としては `\s ->` のほうが普通だが、CLAUDE.md の規約はそれを禁止している。**現実と規約の乖離**。

判定:
- (A) 規約を厳格にして全て `\state ->` にリネーム
- (B) 規約を緩めて「`State` モナドの updater は `\s ->` を許容」と明文化

私の所感: (B) が現実的。`State` モナドの慣習的な束縛 `s` は十分「一般的・抽象的」と見なせる。

#### 違反: `q` ([IR.hs:154](../haskell/katari-compiler/src/Katari/IR.hs#L154))

```haskell
renderQualifiedName q
  | T.null q.module_ = q.name
  | otherwise = q.module_ <> "." <> q.name
```

`q :: QualifiedName`。フルネームなら `qualifiedName` または `name`。しかし lambda じゃなく function arg の `q` はやや軽め。

#### 違反: `t`, `n` 等 ([IR.hs:161](../haskell/katari-compiler/src/Katari/IR.hs#L161))

```haskell
parseQualifiedName :: Text -> QualifiedName
parseQualifiedName t = ...
```

`t :: Text` を意味する `t`。フルネームなら `text` あるいは `qualifiedNameText`。

### 4.5 汎用コンビネータの束縛変数

#### 規約: 具体名がある場合は略語を避ける。`(element : remaining)` ○、`(x : xs)` ✗

実例調査:

```sh
grep -rE '\([a-z] : [a-z]+\)' Katari/
```
これは ad-hoc には確認できなかったが、`Lexer.hs:955` の
```haskell
WithSourceSpan span_ _ : _ -> mkSourcePos span_.filePath span_.start
```
は `_:_` パターンなので問題なし。

具体的違反は探せず。✓

### 4.6 型パラメータ

#### 規約: なるべく一文字を避ける。意味のある名前。

実例:
- `class HasSourceSpan node where` ([SourceSpan.hs:29](../haskell/katari-compiler/src/Katari/SourceSpan.hs#L29)) — 規約遵守 ✓
- `data WithSourceSpan wrapped` (Lexer 内) — 確認不要だが、もし `WithSourceSpan a` だったら違反。

`Phase`, `NameRefKind` など型パラメータは具体名。✓

ただし [AST.hs:1174-1176](../haskell/katari-compiler/src/Katari/AST.hs#L1174-L1176):
```haskell
deriving instance (Eq (NameRefResolution p s)) => Eq (NameRef p s)
```

`p` (phase) と `s` (NameRefKind) は 1 文字。
[AST.hs:1138](../haskell/katari-compiler/src/Katari/AST.hs#L1138):
```haskell
class (...) => EqPhase phase
```

ここでは `phase` フルネーム。**不整合**。

修正: standalone deriving の type variable も `phase` / `nameRefKind` に揃えるべき。

## 全体スコア

| 規約 | 遵守度 | 主な違反 |
| --- | --- | --- |
| 1. 関数羅列を避ける | ✓ ほぼ完璧 | 違反なし |
| 2. 便利構文の活用 | ✓ 完璧 | なし |
| 3. データ定義そのまま | ✓ 完璧 | なし |
| 4.1 型名フルワード | ⚠ 軽微 | `BlockCtor` / `ReqId` / `CtorId` の略語 |
| 4.2 フィールド/局所変数フルワード | ⚠ 中程度 | `params`, `ctx`, `zr`, `dp` 等 |
| 4.3 parse/lex プレフィックス | ⚠ 軽微 | Lexer の `classifySurrogate` |
| 4.4 ローカル変数 | ⚠ 中程度 | `\s ->` State updater (規約と慣習の乖離) |
| 4.5 汎用コンビネータ | ✓ | なし |
| 4.6 型パラメータ | ⚠ 軽微 | standalone deriving の `p`/`s` |

## 推奨アクション

### A. 機械的修正で済むもの (~半日)

1. `params` → `parameters` の rename (Schema, ConstraintGen, Exhaustive)
2. `ctx` → `context` の rename (Exhaustive, ConstraintGen)
3. `zr` → `zonkResult` の rename (Exhaustive)
4. `colType` → `columnType` (Exhaustive)
5. `dp` → `dataParameter` (Schema)
6. standalone deriving の type variable を `phase` / `nameRefKind` に統一 (AST.hs)

### B. 議論すべきもの

7. `BlockCtor` / `ReqId` / `CtorId` を `BlockConstructor` / `RequestId` / `ConstructorId` にリネーム (IR の breaking change を伴う)
8. `\s -> s {...}` を `\state -> state {...}` に統一するか、CLAUDE.md に「`State` updater 例外」を追記するかの判断

### C. 既存の慣習を変えない (見送り)

9. `parseQualifiedName t = ...` の `t` (Text) → `text` まで遡る pedantic 修正は割に合わない

## 全体評価

**規約 1-3 はほぼ完璧に遵守**されており、規約 4 (命名) に局所的な乱れがある。意図的な逸脱というより「一部のモジュール・著者で慣習がぶれた」程度。

`Exhaustive.hs` (569 行) と `Schema.hs` (491 行) が違反のホットスポット。OSS 公開前に **このうち rename 系の機械的修正だけは適用**しておくと、コードベース全体の一貫性が大きく上がる。

## 後段で追跡すべき未解決事項

- [ ] `BlockCtor`/`CtorId`/`ReqId` の rename を runtime 再設計のタイミングで実施するか議論
- [ ] CLAUDE.md に「`State` updater の `\s ->` を許容」を追記するか
