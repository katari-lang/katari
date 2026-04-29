# KATARI プロジェクト

KATARI 言語のコンパイラ・ランタイム・LSP の実装リポジトリ。

## プロジェクト構成

```
haskell/
  katari-compiler/   # コンパイラライブラリ (pure / IO なし)
  katari-cli/        # CLI ツール (executable: katari) — 現在再設計中
  katari-lsp/        # LSP サーバー — 現在再設計中
ts/                  # TypeScript 実装 (pnpm workspace)
  packages/
    katari-protocol/         # Katari Protocol ライブラリ (型, Store, Server, Router)
    katari-runtime/          # ランタイム — 現在再設計中 (新 IR JSON に合わせ作り直し予定)
    katari-discord-server/   # Discord 外部サーバー
    katari-ai-server/        # AI (Gemini) 外部サーバー
    katari-cron-server/      # Cron 外部サーバー
    katari-websearch-server/ # Web 検索外部サーバー
    katari-sandbox-server/   # Docker サンドボックス外部サーバー
haskell-old/         # 旧実装 (参考用)
samples/             # haskell-old の旧 syntax を使う未対応サンプル群 (compiler の参照対象外)
```

## ビルド・実行

```sh
# Haskell コンパイラのビルドと test
stack build
stack test

# Haddock
stack haddock katari-compiler --no-haddock-deps

# TypeScript (pnpm v9 を使用)
cd ts && pnpm install && pnpm -r run build
```

### pnpm バージョン

pnpm v10 にワークスペース検出のバグがあるため、pnpm v9 を使用。
`package.json` の `packageManager` フィールドで `pnpm@9.15.9` を指定済み。

## コンパイラパイプライン

`katari-compiler` は **完全に pure** (file IO なし)。`Map ModuleName Text` を入力にとり、
diagnostic と IR (JSON 化可能) と Schema を出力する。

```
.ktr ソース (Map ModuleName Text)
  → Katari.Lexer                   Char stream → [WithPos Token], 仮想セミコロン挿入
  → Katari.Parser                  Token stream → Module Parsed (megaparsec カスタムストリーム)
  → Katari.Typechecker.Identifier  名前解決, VariableId / TypeId / ModuleId 発行
  → Katari.Typechecker.ConstraintGenerator  制約生成
  → Katari.Typechecker.Solver      制約解決 (subtype, effect)
  → Katari.Typechecker.Zonker      Resolved 型に確定
  → Katari.Lowering                AST Zonked → IRModule (JSON 化可能)
  ┖ Katari.Schema                  ZonkResult → SchemaBundle (AI tool calling 用 JSON Schema)
```

統一エントリは [Katari.Compile](haskell/katari-compiler/src/Katari/Compile.hs):

```haskell
compile :: CompileInput -> CompileResult
```

各 phase は独自エラー型を返すが、最終的に [Katari.Diagnostic](haskell/katari-compiler/src/Katari/Diagnostic.hs)
の統一 `Diagnostic` (severity, code, span, message, ...) に変換される。

## AST: Trees-that-Grow

AST ノードは `(p :: Phase)` でパラメータ化:

```haskell
type data Phase = Parsed | Identified | Constrained | Zonked
```

- `NameRef p s` の `resolution :: NameMeta p s` フィールドに phase 別の名前解決情報
  (`Identified` 以降は `Maybe VariableId` / `Maybe TypeId` / `Maybe ModuleId`)。
- `Expression p` / `Pattern p` の `typeOf :: ExprType p` / `PatType p` に推論型
  (`Constrained` で `SemanticType Unresolved`、`Zonked` で `SemanticType Resolved`)。
- phase 推移は payload を素通しする identity 変換になり、`passThroughX` 系の boilerplate は不要。

## IR

IR は **JSON 形式** (binary でない)。runtime は JSON を直接読む。

- `Block` は GADT (`BlockUser` / `BlockPrim` / `BlockRequest` / `BlockExternal` / `BlockCtor`)
- `BlockKind` enum で `UserBlock` の役割を表現:
  - `BlockAgentEntry` — agent 本体 (catchesReturn)
  - `BlockAgentEntryWithHandlers` — `where { handlers }` 付き agent
  - `BlockHandleScope` — `where (var s = init) ...` の内側 scope (catchesBreak + inheritScope)
  - `BlockInline` — inline block / arm body / for body / then block
  - `BlockHandlerBody` — request handler 本体
- `Statement` は GADT (`SCall` / `SMakeClosure` / `SLoadLiteral` / `SMatch` / `SFor` / `SExit` / `SCont`)
- ToJSON / FromJSON は `genericToJSON` で自動生成 (`TaggedObject` sumEncoding)

## 重要な実装詳細

### セミコロン自動挿入 (Katari.Lexer)

レキサーは空白・コメントを破棄し、`\n` のみ中間トークン `TokenNewline` として残す。
`insertVirtualSemis` が各 `TokenNewline` について直前トークンが以下のいずれかなら `TokenSemicolon` に置換、そうでなければ破棄する:

- 識別子, 数値・文字列リテラル, テンプレリテラル閉じ
- `break`, `return`, `next`, `null`, `true`, `false`, 型キーワード (`integer`, `boolean`, `number`, `string`)
- `)`, `]`, `}`

括弧深度は追跡しない (Go 流儀)。言語規約で担保:

- 複数行リスト (引数・配列・enum コンストラクタ等) は **末尾カンマ必須**
- `else` / `then` / `where` は直前の `}` と同じ行
- 演算子での改行は **演算子を行末**に置く

テンプレリテラル `f"..."` / `f"""..."""` はレキサーがスタック で「文字列モード ↔ 式モード」を管理し、
`TemplateOpen` / `TemplateString` / `TemplateExpressionOpen` / `TemplateExpressionClose` / `TemplateClose` トークンを発行する。

### break / next の文脈判別 (Parser)

`BreakContext` (`TopContext` | `BreakForContext` | `BreakHandleContext`) を `ReaderT` でパーサーに引き回す。

| コンテキスト                              | 許可される文                           |
| ----------------------------------------- | -------------------------------------- |
| `TopContext` (agent 本体)                 | `break` / `next` 両方禁止 (構文エラー) |
| `BreakForContext` (for 本体)              | `ForNext` (引数なし) / `ForBreak`      |
| `BreakHandleContext` (req handler 本体)   | `Next` (引数あり) / `Break`            |

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

Pattern destructuring: `bindPatternLocals` / `bindPatternToFreshVar` 共通の
`destructurePattern` が tuple/constructor を `tuple_get` / `get_field` prim 呼び出しで再帰的に分解。

Local agent (`StatementAgent`): 親 scope に新しい BlockId を allocate し
`lsVarBlockIds` に登録、body は empty Reader で lower (closure capture は未対応)。

### 型チェック

- `let x: T = e` — 推論型が `T` のサブタイプか検証
- agent / req の return 型 — ボディ型が宣言 return 型のサブタイプか検証
- 未定義変数 — `IdentifierError` (`NTUnknown` フォールバックなし)
- effect — `WhereBlock` の `req` handler が agent body の effect 集合をカバーするか検証

### for 式の型

- `for(...) { body } then { fin }` の型 = `finType ∪ breakType`
- `for(...) { body }` の型 = `null ∪ breakType`

`breakType` は本体を走査して収集する (内側の for には潜らない)。

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
