# KATARI プロジェクト

KATARI 言語のコンパイラ・ランタイム・LSP の実装リポジトリ。

## プロジェクト構成

```
haskell/
  katari-compiler/   # コンパイラライブラリ（library）
  katari-cli/        # CLI ツール（executable: katari）
  katari-lsp/        # LSP サーバー
rust/                # Katari ランタイム（Rust）
doc/spec/            # 言語仕様書（00〜10）
```

## ビルド・実行

```sh
# ビルド
just build-hs              # 全 Haskell パッケージ
just build-compiler        # コンパイラのみ
just build-cli             # CLI のみ

# CLI 実行
stack exec katari -- compile <file.ktr> -o <file.ktri>
stack exec katari -- dump <file.ktr>   # IR をテキストダンプ

# Rust ランタイム
just build-rust
just run-runtime <args>
```

## コンパイラパイプライン

```
.ktr ファイル
  → Lexer.hs       トークン化（セミコロン自動挿入）
  → Parser.hs      AST 生成（megaparsec）
  → Module.hs      モジュールロード・名前解決
  → Typechecker.hs 型チェック・エフェクト検証
  → Lowering.hs    AST → IR
  → Emit.hs        IR → KTRI バイナリ
```

## 重要な実装詳細

### セミコロン自動挿入（Lexer.hs）

行末トークンが識別子・リテラル・`}`・`)`・`]`・`break`・`return`・`reply`・`next` 等のとき、
次行先頭が `.`・`)`・`]`・`}`・`case`・`else`・`finally`・`of` でなければ改行にセミコロンを挿入。
→ `noSemiBefore` と `noSemiAfter` のリストで制御している。

### Handle スコープ（Lowering.hs）

`handle` 文は「文」でその位置から囲むブロック末尾までがスコープ。
Lowering では `SHandle` 以降の残り文を先読みして `IHandleBegin → scope body → IHandleEnd` を生成する。

`IHandleEnd dst scopeVar hid` — ランタイムが scopeVar の値を return case に渡し、結果を dst に入れる。

### break の文脈判別

- `for` ブロック内の `break` → `SForBreak` → `IForBreak`（for ループ脱出）
- `handle` スコープ内の `break` → `SBreak` → `IBreak`（handle スコープ脱出）

`BreakCtx` (`BreakForCtx` | `BreakHandleCtx`) をパーサーに引き回して判別。
`for_break` キーワードは廃止済み（`break` に統一）。

### for 式の型

`for(...) { body } finally { fin }` の型 = `finType ∪ breakType`
`for(...) { body }` の型 = `null ∪ breakType`

`breakType` は `collectForBreakNT` で本体を走査して収集（内側の for には潜らない）。

### IRHandleBlock

```haskell
data IRHandleBlock = IRHandleBlock
  { irhId         :: HandlerId
  , irhStateVars  :: [VarId]
  , irhReqCases   :: [(RequestId, [VarId], [Instruction])]  -- arg_vars を含む
  , irhReturnCase :: Maybe (VarId, [Instruction])            -- input_var を含む
  }
```

return case の命令列は `IBreak retV hid` で終わる（`IReturn` ではない）。

### for ループ state 変数の更新

`next with { acc = acc + x }` は `IMove targetV newV` に直接変換される（スロットインデックスは使わない）。

### 型チェック

- `let x: T = e` — 推論型が `T` のサブタイプか検証（`PTyped` パターン）
- task の return 型 — ボディ型が宣言 return 型のサブタイプか検証
- `SHandle` — state var 初期値・request case・return case を全て型チェック
- 未定義変数 — `UndefinedName` エラー（`NTUnknown` フォールバックなし）

## バイナリフォーマット（KTRI）

- ヘッダ: `4b 54 52 49 00 01`（"KTRI" + version）
- 整数は LEB128 unsigned
- 文字列: LEB128(length) + UTF-8
- 命令: opcode (u8) + 引数

## 仕様書

`doc/spec/` に仕様書がある。型システムは `02-type-system.md`・`03-discriminated-unions.md`、
リクエスト・handle セマンティクスは `04-request-system.md`、IR は `08-ir.md` を参照。

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
