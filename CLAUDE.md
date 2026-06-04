# KATARI プロジェクト

**Do not use agents**

KATARI 言語のコンパイラ・ランタイム・LSP の実装リポジトリ。

## プロジェクト構成

```
haskell/
  katari-compiler/   # コンパイラ library (pure / IO なし)
  katari-project/    # katari.toml / lockfile / snapshot / package resolution
  katari/            # CLI binary (executable: katari)
  katari-lsp/        # LSP サーバー (再設計中)
typescript/          # TypeScript 実装 (pnpm workspace)
  packages/
    katari-runtime/      # ランタイム本体 (pure core + HTTP server)
    katari-api-server/   # runtime を HTTP で expose する server
    katari-port/         # 外部サーバー共通 port abstraction
    katari-bundle/       # esbuild bundler (katari binary が spawn する CLI)
    katari-vscode/       # VSCode extension
e2e/                 # end-to-end test (samples + tests)
```

## ビルド・実行

```sh
# Haskell (compiler / katari-project / katari binary / lsp)
stack build
stack test

# Haddock
stack haddock katari-compiler --no-haddock-deps

# TypeScript (pnpm v9 を使用)
cd typescript && pnpm install && pnpm -r run build
```

### pnpm バージョン

`packageManager` フィールドで `pnpm@11.1.3` を pin。

注意:

- pnpm 11 はデフォルトで `minimumReleaseAge` (~14h) を強制するため、
  公開直後の dep が lockfile に入っていると install が止まる。
  当面 `pnpm-workspace.yaml` で 0 に緩めている。
- pnpm 11 は postinstall script の明示的 approve が必須
  (`allowBuilds:` に列挙)。 現状 `esbuild` / `keytar` /
  `@vscode/vsce-sign` を承認済み。

## コンパイラパイプライン

`katari-compiler` は **完全に pure** (file IO なし)。`Map ModuleName Text` を入力にとり、
diagnostic と IR (JSON 化可能) と Schema を出力する。

```
.ktr ソース (Map ModuleName Text)
  → Katari.Lexer                   Char stream → [WithPos Token], 仮想セミコロン挿入
  → Katari.Parser                  Token stream → Module Parsed (megaparsec カスタムストリーム)
  → Katari.Typechecker.Identifier  名前解決, 5 id 名前空間 (VariableId / TypeId / ModuleId / RequestId / ConstructorId) 発行
  → Katari.Typechecker.Check        bidirectional 型検査 (synth/check) + effect 推論 (再帰=注釈必須・非再帰=単一パス) → Module Zonked
  → Katari.Typechecker.Exhaustive   網羅性 / 到達性検査 (Maranget)
  → Katari.Lowering                AST Zonked → IRModule (JSON 化可能)
  ┖ Katari.Schema                  Zonked module + type env → SchemaBundle (AI tool calling 用 JSON Schema)
```

型検査は **bidirectional checker** ([Katari.Typechecker.Check](haskell/katari-compiler/src/Katari/Typechecker/Check.hs)) に一本化されている。型変数・制約・unification・zonking は無い (全 callable の引数型が必須注釈なので、synth/check の単一トップダウン walk で確定する)。subtype は `Katari.Typechecker.NormalizedType` の純関数を直接呼ぶ。`Katari.Typechecker` が SCC ごとに `checkSCC` を回す。

統一エントリは [Katari.Compile](haskell/katari-compiler/src/Katari/Compile.hs):

```haskell
compile :: CompileInput -> CompileResult
```

各 phase は独自エラー型を返すが、最終的に [Katari.Diagnostic](haskell/katari-compiler/src/Katari/Diagnostic.hs)
の統一 `Diagnostic` (severity, code, span, message, ...) に変換される。

## AST: Trees-that-Grow

AST ノードは `(p :: Phase)` でパラメータ化:

```haskell
type data Phase = Parsed | Identified | Zonked
```

- `NameRef p s` の `resolution :: NameRefMeta p s` フィールドに phase 別の名前解決情報。
  `s :: NameRefKind` で「変数 / 型 / モジュール / ラベル / req / data ctor」を分離:
  - `VariableRef` → `Maybe VariableId` (agent / req / ext / ctor の callable 側 / 局所変数)
  - `TypeRef` → `Maybe TypeId`
  - `ModuleRef` → `Maybe ModuleId`
  - `LabelRef` → `()` (型指向で typechecker が解決)
  - `RequestRef` → `Maybe RequestId` (req handler の target、`req foo` 宣言のみ占有)
  - `ConstructorRef` → `Maybe ConstructorId` (match constructor pattern の target、`data Foo` のみ占有)
- `Expression p` / `Pattern p` の `typeOf :: ExprType p` / `PatType p` に推論型
  (`Zonked` で `SemanticType Resolved`; `Parsed` / `Identified` は `()`)。型変数を持つ
  中間 phase は無い — checker が `Identified` から直接 `Zonked` (= Resolved 型付き) を作る。
- phase 推移は payload を素通しする identity 変換になり、`passThroughX` 系の boilerplate は不要。

`RequestRef` / `ConstructorRef` を slot 分離した結果、「handler target が req でない」「match
pattern が data ctor でない」は Identifier 段階で型レベルに reject される
(`ErrorNotARequest` K0108 / `ErrorNotAConstructor` K0109)。Lowering まで届くことはない。

## IR

IR は **JSON 形式** (binary でない)。runtime は JSON を直接読む。

### ID 空間と公開名

IR 内部の dispatch は専用 id 型で行い、外部公開 (FFI / JS) は `QualifiedName` で行う
二層構造:

- `BlockId` — IR の callable 識別 (`SCall` / `SMakeClosure` の target、`Map BlockId Block` のキー)
- `VarId` — IR の値スロット (Lowering が per-occurrence で発行)
- `ReqId` — `BlockRequest` 内部の dispatch id (`Handler.request` と同値比較)
- `CtorId` — `BlockCtor` 内部の dispatch id (tagged value の `__ctor` と同値比較)
- `QualifiedName` (`{ module_, name }`) — FFI 境界の公開名

`IRModule.entries :: Map QualifiedName BlockId` のみが FFI 名前解決の SSoT。逆引きや
ReqId / CtorId → QualifiedName 変換は runtime が `entries` + `blocks` を load 時に
1 周走査して構築する (IR には含めない)。

### Block

`Block` は 5 variant の sum:

- `BlockUser { body :: UserBlock }` — 通常のユーザ定義
- `BlockPrim { name :: Text }` — prim (system 提供、module 帰属なし)
- `BlockRequest { reqId :: ReqId }` — req 宣言 (qualified name は `entries` 経由)
- `BlockExternal { externalName :: ExternalName }` — JS sidecar 呼び出し対象
- `BlockCtor { ctorId :: CtorId }` — data constructor

`UserBlock.kind :: BlockKind` (5 valid roles, invalid 組合せは型レベルで排除):

- `BlockAgentEntry` — agent 本体 (catchesReturn)
- `BlockAgentEntryWithHandlers` — `where { handlers }` 付き agent
- `BlockHandleScope` — `where (var s = init) ...` の内側 scope (catchesBreak + inheritScope)
- `BlockInline` — inline block / arm body / for body / then block
- `BlockHandlerBody` — request handler 本体

### Match

`MatchArm` は構造的な pattern tree を保持し、runtime が値と pattern を walk して match:

```haskell
data MatchPattern
  = MPAny
  | MPVariable VarId
  | MPLiteral LiteralValue
  | MPConstructor CtorId [(Text, MatchPattern)]
  | MPTuple [MatchPattern]
```

source の 1 arm = IR の 1 arm。任意深度ネスト・同 tag arm overlap も自動対応 (runtime が arm を
順次試行)。Lowering は AST pattern を MatchPattern に直訳するだけ (~30 行)。

### Closure capture

local agent (`StatementAgent`) の closure capture は **runtime の lexical scope inheritance に委譲**。
`UserBlock.captures` / `MakeClosureData.captures` は予約フィールドだが現状空。Katari の意味論では
state var が agent から見て immutable (next で更新できるのは req handler のみ) なので by-value
snapshot と by-reference scope inheritance は観測等価。

### Statement / JSON

- `Statement` は GADTs 構文 + sumEncoding:
  `StatementCall` / `StatementMakeClosure` / `StatementLoadLiteral` / `StatementMatch` /
  `StatementFor` / `StatementExit` / `StatementCont` / `StatementBindPattern`
- `MatchPattern` は `MatchPatternAny` / `MatchPatternVariable` / `MatchPatternLiteral` /
  `MatchPatternConstructor` / `MatchPatternTuple`
- `CallTarget` は `CallTargetBlock` / `CallTargetValue`
- ToJSON / FromJSON は `genericToJSON` で自動生成 (`TaggedObject` sumEncoding)
- JSON tag はコンストラクタ名に `lowerHead` を適用した camelCase (例: `"statementCall"` / `"matchPatternAny"`)。
  `constructorTagModifier = lowerHead` を使用

## 重要な実装詳細

### セミコロン自動挿入 (Katari.Lexer)

レキサーは空白・コメントを破棄し、`\n` のみ中間トークン `TokenNewline` として残す。
`insertVirtualSemis` が各 `TokenNewline` について直前トークンが以下のいずれかなら `TokenSemicolon` に置換、そうでなければ破棄する:

- 識別子, 数値・文字列リテラル, テンプレリテラル閉じ
- `break`, `return`, `next`, `null`, `true`, `false`, 型キーワード (`integer`, `boolean`, `number`, `string`)
- `)`, `]`, `}`

`(` / `[` の中では仮想セミコロン挿入を抑止する (depth カウンタで追跡)。これにより複数行の引数リスト・配列リテラルでは末尾カンマを書かなくてよい。`{` は block 区切りでもあるため抑止対象外 (block 内では従来どおり改行が文区切りとして機能する)。

言語規約:

- `else` / `then` / `where` は直前の `}` と同じ行
- 演算子での改行は **演算子を行末**に置く

テンプレリテラル `f"..."` / `f"""..."""` はレキサーがスタック で「文字列モード ↔ 式モード」を管理し、
`TemplateOpen` / `TemplateString` / `TemplateExpressionOpen` / `TemplateExpressionClose` / `TemplateClose` トークンを発行する。

### break / next の文脈判別 (Parser)

`BreakContext` (`TopContext` | `BreakForContext` | `BreakHandleContext`) を `ReaderT` でパーサーに引き回す。

| コンテキスト                            | 許可される文                           |
| --------------------------------------- | -------------------------------------- |
| `TopContext` (agent 本体)               | `break` / `next` 両方禁止 (構文エラー) |
| `BreakForContext` (for 本体)            | `ForNext` (引数なし) / `ForBreak`      |
| `BreakHandleContext` (req handler 本体) | `Next` (引数あり) / `Break`            |

- `for` ブロック内の `break` → `StatementForBreak` → `SExit ExitForBreak` (for ループ脱出)
- `where { handlers }` 内の `break` → `StatementBreak` → `SExit ExitBreak` (handle スコープ脱出)

### Annotation 構文

各宣言は `@"..."` 形式の文字列 annotation を持てる ([Parser.hs `parseAnnotation`](haskell/katari-compiler/src/Katari/Parser.hs)):

```katari
@"Greets a user by name."
agent greet(name = name: string) -> string { ... }
```

Annotation は AST に `annotation :: Maybe Text` として保持され、Schema 生成時に
JSON Schema の `description` に埋め込まれる (AI tool calling 用)。SemanticType には
入らない (subtyping 等のノイズになるため)。

### Lowering (Writer/Reader 化済み)

`Lower = ReaderT LowerEnv (State LowerState)`

- `LowerEnv.localVars :: Map VariableId VarId` — 局所束縛 (Reader 化、`local`-restorer 不要)
- `LowerState.lsCurrentEmitted :: [Statement]` — 現在 build 中の block の statements (逆順)
- `emit` で蓄積、`runWithFreshBuffer` で save/restore、reverse して取り出し
- `LowerState.lsTopLevelBlocks :: Map VariableId BlockId` — top-level callable のみ (local agent は localVars に入る)
- `LowerState.lsReqIds :: Map Identifier.RequestId IR.ReqId` / `lsCtorIds :: Map Identifier.ConstructorId IR.CtorId`
  — Identifier id → IR 内部 id への翻訳 (Lowering が re-index)
- `LowerState.lsEntries :: Map QualifiedName BlockId` — FFI translation (IRModule.entries の素材)

Pattern destructuring (let / param): `destructurePattern` が tuple / constructor を再帰的に分解
(`tuple_get` / `get_field` prim 呼び出し)。refutable pattern (literal) は
`LowerErrorRefutablePatternInIrrefutableContext` (K0303) で reject。

Match: `lowerPattern` が AST.Pattern を IR.MatchPattern に直訳するだけ。inner refutable / nested
constructor / overlap は IR には現れず runtime が解決。

Local agent (`StatementAgent`): 親 scope の `localVars` をそのまま inherit して body を lower。
runtime が closure 値の lexical scope を構成する。

### 型チェック

- `let x: T = e` — 推論型が `T` のサブタイプか検証
- agent / req の return 型 — ボディ型が宣言 return 型のサブタイプか検証
- 未定義変数 — `IdentifierError` (`NTUnknown` フォールバックなし)
- effect — `WhereBlock` の `req` handler が agent body の effect 集合をカバーするか検証

### for 式の型

- `for(...) { body } then { fin }` の型 = `finType ∪ breakType`
- `for(...) { body }` の型 = `null ∪ breakType`

`breakType` は本体を走査して収集する (内側の for には潜らない)。

## 公開 API サマリ

`katari-compiler` の公開モジュール (semver 管理対象):

| モジュール                 | 役割                                                                              |
| -------------------------- | --------------------------------------------------------------------------------- |
| `Katari.Compile`           | 統一エントリ (`compile :: CompileInput -> CompileResult`)                         |
| `Katari.Diagnostic`        | 統一 Diagnostic 型 + helpers (`filterAtLeast` / `sortBySpan` / `groupByFilePath`) |
| `Katari.Diagnostic.Render` | CLI 向けレンダリング (`renderDiagnostic` / `renderDiagnosticPlain`)               |
| `Katari.IR`                | IR データ型 + JSON シリアライゼーション                                           |
| `Katari.Schema`            | JSON Schema bundle (AI tool calling 用)                                           |
| `Katari.Query`             | LSP / CLI 向け query layer (position lookup / occurrence index)                   |
| `Katari.AST`               | AST 型 + phase-indexed metadata                                                   |
| `Katari.Identifiers`       | ID 型 (`VariableId`, `TypeId`, ...) + `QualifiedName`                             |
| `Katari.SemanticType`      | 意味型 (`SemanticType`, `SemanticEffect`) + traversal                             |

### CompileResult

```haskell
data CompileResult = CompileResult
  { irModule      :: !(Maybe IRModule)        -- Error diagnostic があれば Nothing
  , schemaEntries :: !(Maybe [SchemaEntry])   -- 同上
  , diagnostics   :: ![Diagnostic]
  , querySnapshot :: !Query.QuerySnapshot     -- Query layer (hover / completion) 用
  , updatedCache  :: !(Map ModuleName ModuleCache)  -- incremental back-end cache
  }
```

### IRModule.metadata

```haskell
data IRMetadata = IRMetadata
  { schemaVersion :: !Int   -- 現在 = 1; runtime が version skew を検知
  }

data IRModule = IRModule
  { metadata  :: !IRMetadata
  , name      :: !Text           -- root module name
  , blocks    :: !(Map BlockId Block)
  , entries   :: !(Map QualifiedName BlockId)
  , nameTable :: !NameTable
  }
```

### Katari.Query

```haskell
-- Hover 情報: position → 最内ノードの型情報
lookupAtPosition :: QuerySnapshot -> FilePath -> Position -> Maybe HoverInfo

-- Occurrence index: 一度 build して繰り返し query
buildOccurrenceIndex :: QuerySnapshot -> OccurrenceIndex

-- find-references / go-to-definition
identifyAtPosition :: QuerySnapshot -> FilePath -> Position -> Maybe ResolvedReference
findReferences     :: OccurrenceIndex -> ResolvedReference -> [SourceSpan]
findDefinition     :: QuerySnapshot -> FilePath -> Position -> Maybe SourceSpan
```

Position は **code-point 単位** (LSP layer が UTF-16 オフセットを変換してから渡す)。

### Katari.Diagnostic.Render

```haskell
-- snippet 付き (source map あり)
renderDiagnostic      :: Map FilePath Text -> Diagnostic -> Text

-- snippet なし (source map なし)
renderDiagnosticPlain :: Diagnostic -> Text
```

`Katari.Diagnostic` 本体に source text 依存を持ち込まないため別モジュールに分離。

## Katari Protocol (TS Runtime 側 — 再設計予定)

エージェント間通信プロトコル。主要エンドポイント:

- `POST /delegate` — 子エージェントの起動
- `POST /delegate_ack` — 子完了通知 (output 返却)
- `POST /escalate` — Capability への要求 (handle block で処理)
- `POST /escalate_ack` — Escalation 応答
- `POST /terminate` / `/terminate_ack` — 子エージェント停止
- `POST /throw` — エラー伝搬

主要概念: Agent, Delegation, Template, Capability, Escalation。
新 IR JSON に合わせて TS runtime は作り直す予定。

## Haskell コーディング規約

トークン数を抑え、関数の意図を明確にするため、以下の規約に従う。

### 1. 関数羅列によるパターンマッチを避ける

複数の等式でパターンマッチする代わりに、単一の関数定義内で `case` / `\case`
を使う。理由: 関数名・型注釈を 1 度だけ書けば済み、トークン数が減る。

```haskell
-- ❌ 関数羅列
foo :: Bar -> Int
foo Bar1 = 1
foo Bar2 = 2
foo _    = 0

-- ✅ \case
foo :: Bar -> Int
foo = \case
  Bar1 -> 1
  Bar2 -> 2
  _    -> 0

-- ✅ 複数引数で 1 つの引数を分解する場合
foo :: Bar -> Int -> Int
foo x y = case x of
  Bar1 -> y + 1
  Bar2 -> y - 1
  _    -> y

-- ✅ 二項関数: タプル分解
unionNT :: NormalizedType -> NormalizedType -> NormalizedType
unionNT a b = case (a, b) of
  (NTNever, _) -> b
  (_, NTNever) -> a
  ...
```

### 2. 便利構文の積極利用

- `LambdaCase`: 単一引数の case 分岐
- `RecordWildCards`: レコード分解 (`SomeRec {..}`)
- ガード: 値による条件分岐
- `where` バインディング: 局所定義の整理

`katari-compiler.cabal` で `LambdaCase`・`TupleSections`・`RecordWildCards`・
`OverloadedStrings`・`StrictData` を `default-extensions` に登録済み。

### 3. データ定義はそのまま

`data` / `newtype` 宣言は規約の対象外。型クラスインスタンスも、メソッドが
本質的に複数等式である場合 (例: `compare` の対称分岐) は無理に統合しない。
パーサーコンビネータのように `do` 記法中心の関数も自然な形を維持する。

### 4. 命名規則

**型名・コンストラクタ名**: フルワードを使う。略語禁止。コンストラクタ名には
型名をプレフィックスとして付ける (例: `TokenIdentifier`, `KeywordFor`,
`PunctuationLeftBrace`, `BinaryOperatorAdd`, `ExpressionLiteral`)。`AST.hs` を参照。

**直和型**: GADTs 構文 (`data T where ...`) を使う。

**レコードフィールド**: `NoFieldSelectors` 有効のためプレフィックス不要。
フィールド名はフルワード (例: `sourcePosition`, `tokenLength`, `parameters`)。
省略形は使わない (`params` ✗, `args` ✗, `op` ✗, `ins` ✗)。

**Parser を返す関数**: 全て `parse` プレフィックス
(例: `parseImport`, `parseKeyword`, `parseCurrentPosition`)。
**Lexer 内の関数**: `lex` プレフィックス
(例: `lexIdentifierOrKeyword`, `lexTemplateBodyToken`)。

**ローカル変数**: 抽象的なコードのみ一文字可 (例: 純粋に汎用な型クラスメソッド内)。
具体的なドメイン値はフルネームを使う
(例: `filePath` ○, `fp` ✗; `expression` ○, `ex` ✗; `startPosition` ○, `s` ✗)。

**汎用コンビネータの束縛変数**: 具体名がある場合は略語を避ける
(例: `(element : remaining)` ○, `(x : xs)` ✗)。

**型パラメータ**: なるべく一文字を避ける。意味のある名前を付ける
(例: `class HasSourceSpan node`, `data WithPosition wrapped`)。
ただし真に汎用な場合 (Functor / Monad のメソッド等) は短縮可。
