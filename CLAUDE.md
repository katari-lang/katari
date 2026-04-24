# KATARI プロジェクト

KATARI 言語のコンパイラ・ランタイム・LSP の実装リポジトリ。

## プロジェクト構成

```
haskell/
  katari-compiler/   # コンパイラライブラリ（library）
  katari-cli/        # CLI ツール（executable: katari）
  katari-lsp/        # LSP サーバー
ts/                  # TypeScript 実装（pnpm workspace）
  packages/
    katari-protocol/       # Katari Protocol ライブラリ (型, Store, Server, Router)
    katari-runtime/        # ランタイム (IR 実行, イベントディスパッチ, DB 永続化)
    katari-discord-server/ # Discord 外部サーバー
    katari-ai-server/      # AI (Gemini) 外部サーバー
    katari-cron-server/    # Cron 外部サーバー
    katari-websearch-server/ # Web 検索外部サーバー
    katari-sandbox-server/ # Docker サンドボックス外部サーバー
doc/spec/            # 言語仕様書（00〜10）
```

## ビルド・実行

```sh
# Haskell コンパイラ
stack build                # 全 Haskell パッケージ
stack exec katari -- compile <file.ktr> -o <file.ktri>
stack exec katari -- dump <file.ktr>   # IR をテキストダンプ
stack exec katari -- apply             # ランタイムにデプロイ

# TypeScript (pnpm v9 を使用)
cd ts && pnpm install && pnpm -r run build

# ランタイム起動 (Node.js)
cd ts/packages/katari-runtime && pnpm start

# ランタイム (Cloudflare Workers)
cd ts/packages/katari-runtime && pnpm dev:worker
cd ts/packages/katari-runtime && pnpm deploy

# テスト
cd ts/packages/katari-runtime && pnpm test
```

### pnpm バージョン

pnpm v10 にワークスペース検出のバグがあるため、pnpm v9 を使用。
`package.json` の `packageManager` フィールドで `pnpm@9.15.9` を指定済み。

## コンパイラパイプライン

```
.ktr ファイル
  → Katari.Lexer   Char stream → [WithPos Token]、仮想セミコロン挿入
  → Katari.Parser  Token stream → AST (megaparsec カスタムストリーム)
  → Module.hs      モジュールロード・名前解決
  → Typechecker.hs 型チェック・エフェクト検証
  → Lowering.hs    AST → IR
  → Emit.hs        IR → KTRI バイナリ
```

## 重要な実装詳細

### セミコロン自動挿入（Katari.Lexer）

レキサーは空白・コメントを破棄し、`\n` のみ中間トークン `TNewline` として残す。
`insertVirtualSemis` が各 `TNewline` について直前トークンが以下のいずれかなら `TSemi` に置換、そうでなければ破棄する:

- 識別子 (`TIdent`)
- 数値・文字列リテラル (`TIntLit`, `TFloatLit`, `TStringLit`, `TTemplateClose`)
- `break`, `return`, `next`, `null`, `true`, `false`, 型キーワード (`integer`, `boolean`, `number`, `string`)
- `)`, `]`, `}`

括弧深度は追跡しない（Go 流儀）。言語規約で担保:

- 複数行リスト（引数・配列・enum コンストラクタ等）は **末尾カンマ必須**
- `else` / `then` / `where` は直前の `}` と同じ行
- 演算子での改行は **演算子を行末**に置く

テンプレリテラル `f"..."` / `f"""..."""` はレキサーがスタック (`[LexerCtx]`) で「文字列モード ↔ 式モード」を管理し、
`TTemplateOpen` / `TTemplateStr` / `TTemplateExprOpen` / `TTemplateExprClose` / `TTemplateClose` トークンを発行する。

### Handle スコープ（Lowering.hs）

`handle` 文は「文」でその位置から囲むブロック末尾までがスコープ。
Lowering では `SHandle` 以降の残り文を先読みして `IHandleBegin → scope body → IHandleEnd` を生成する。

`IHandleEnd dst scopeVar hid` — ランタイムが scopeVar の値を return case に渡し、結果を dst に入れる。

### break / next の文脈判別

`BreakCtx` (`TopCtx` | `BreakForCtx` | `BreakHandleCtx`) を `ReaderT` でパーサーに引き回す。

| コンテキスト                        | 許可される文                           |
| ----------------------------------- | -------------------------------------- |
| `TopCtx` (agent 本体)               | `break` / `next` 両方禁止 (構文エラー) |
| `BreakForCtx` (for 本体)            | `ForNext` (引数なし) / `ForBreak`      |
| `BreakHandleCtx` (req handler 本体) | `Next` (引数あり) / `Break`            |

- `for` ブロック内の `break` → `StatementForBreak` → `IForBreak`（for ループ脱出）
- `handle` スコープ内の `break` → `StatementBreak` → `IBreak`（handle スコープ脱出）

`for_break` キーワードは廃止済み（`break` に統一）。

### 型注釈の方針

`ParamBinding.pattern` は `Pattern` 型（旧 `TypedPattern` は廃止）。HM 型推論で補える場合は型注釈省略可能。
`WildcardPattern` にも `typeAnnotation :: Maybe SyntacticType` があり `_: integer` の形で使用できる。

### for 式の型

`for(...) { body } finally { fin }` の型 = `finType ∪ breakType`
`for(...) { body }` の型 = `null ∪ breakType`

`breakType` は `collectForBreakNT` で本体を走査して収集（内側の for には潜らない）。

### IRHandleDef

```haskell
data IRHandleDef = IRHandleDef
  { ihdId         :: HandlerId
  , ihdStateVars  :: [VarId]
  , ihdStateInits :: [VarId]
  , ihdBody       :: ThreadId          -- HANDLER_TARGET thread
  , ihdReqCases   :: [(RequestId, ThreadId)]  -- REQUEST_HANDLER threads
  , ihdThen       :: Maybe ThreadId    -- HANDLE_THEN thread
  }
```

Handle のスコープ（残り文）は HANDLER_TARGET thread に、
request case は REQUEST_HANDLER thread に、then 節は HANDLE_THEN thread に分離される。

### for ループ state 変数の更新

`next with { acc = acc + x }` は `IMove targetV newV` に直接変換される（スロットインデックスは使わない）。

### 型チェック

- `let x: T = e` — 推論型が `T` のサブタイプか検証（`PTyped` パターン）
- task の return 型 — ボディ型が宣言 return 型のサブタイプか検証
- `SHandle` — state var 初期値・request case・return case を全て型チェック
- 未定義変数 — `UndefinedName` エラー（`NTUnknown` フォールバックなし）

## バイナリフォーマット（KTRI）

- ヘッダ: `4b 54 52 49 00 03`（"KTRI" + version 0x03）
- 整数は LEB128 unsigned
- 文字列: LEB128(length) + UTF-8
- 命令: opcode (u8) + 引数

## Katari Protocol

エージェント間通信プロトコル。主要エンドポイント:

- `POST /delegate` — 子エージェントの起動 (AgentDefinition → Agent 作成)
- `POST /delegate_ack` — 子完了通知 (output 返却)
- `POST /escalate` — Capability への要求 (handle block で処理)
- `POST /escalate_ack` — Escalation 応答
- `POST /terminate` / `/terminate_ack` — 子エージェント停止
- `POST /throw` — エラー伝搬

主要概念: Agent, Delegation, Template, Capability, Escalation

## ランタイムイベントモデル

ThreadStatus: `CALLING(kind)` | `REQUESTING` | `CANCELING`

CallingKind: `BLOCK` | `AGENT` | `HANDLE_TARGET` | `HANDLE_BODY` | `HANDLE_THEN` | `FOR_BODY` | `FOR_THEN` | `PARALLEL` | `DELEGATING`

RuntimeEvent: `call` | `cancel` | `completed` | `returned` | `continue` | `continued` | `broken` | `for_continued` | `for_broken` | `requested` | `canceled`

Protocol → Runtime マッピング:

- `delegate` → `call`, `delegate_ack` → `completed`
- `escalate` → `requested`, `escalate_ack` → `continue`
- `terminate` → `cancel`, `terminate_ack` → `canceled`

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
