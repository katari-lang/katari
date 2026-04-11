# KATARI 言語概要

本文書は KATARI 言語の全体像を概説する。個別の詳細は各仕様書を参照のこと。

---

## 1. KATARI とは

KATARI は AI オーケストレーションのために設計されたプログラミング言語である。以下の設計思想を軸とする。

### 1.1 Agent ベースの計算モデル

KATARI の基本的な計算単位は **agent** である。agent は `agent` キーワードで宣言される呼び出し可能な単位であり、パラメータ・戻り値型・オプションのエフェクト注釈を持つ。agent は子 agent を spawn し、request を発行し、effect を handle できる。

```katari
agent greet(name: String): String {
  return "Hello, " + name
}
```

### 1.2 協調イベントループ

agent は協調的に実行される。実行の中断 (suspension) は以下の地点でのみ発生する:

- **ICall** — agent 呼び出し
- **IPar** — 並列分岐
- **IRequest** — request 発行

プリエンプティブなスケジューリングは行わない。中断点で request キューが処理される。

### 1.3 代数的エフェクト (handle/request)

KATARI は従来の例外処理の代わりに、代数的エフェクトに類似したエフェクトシステムを採用する。`request` 宣言が操作を定義し、`handle` ブロックがその実装を提供する。

```katari
request ask_user(prompt: String): String

agent main(): Null {
  handle with { prompt_count = 0 } {
    case ask_user(prompt) {
      prompt_count = prompt_count + 1
      reply get_input(prompt)
    }
    return(result) {
      print("Total prompts: " + prompt_count.to_string())
    }
  }

  let answer = ask_user("What is your name?")
}
```

`handle` は文であり、その位置から囲むブロックの末尾までがスコープとなる。

### 1.4 分散実行

agent は異なるサーバー上で実行できる。Katari Protocol (REST API ベース) がサーバー間通信を可能にする。プロトコルは `spawn`・`reply`・`terminate`・`request`・`return`・`terminate_ack` の 6 操作で構成される。詳細は [06-protocol.md](06-protocol.md) を参照。

### 1.5 永続化可能な状態

agent の状態は中断点でシリアライズ可能であり、永続性 (durability) を実現する。サーバー障害からの復旧や、長時間実行される agent の中断・再開を支援する。

---

## 2. プロジェクト構成

```
haskell/
  katari-compiler/   # コンパイラライブラリ (Haskell)
  katari-cli/        # CLI ツール (executable: katari)
  katari-lsp/        # LSP サーバー
rust/                # ランタイム (Rust, 開発中)
doc/spec/            # 言語仕様書 (00-07)
doc/old/             # アーカイブ済み旧ドキュメント
samples/             # サンプル .ktr プログラム
```

---

## 3. コンパイルパイプライン

KATARI ソースコード (`.ktr`) は以下のパイプラインでバイナリに変換される。

```
.ktr ソースファイル
  → Lexer.hs       トークン化 (セミコロン自動挿入)
  → Parser.hs      AST 生成 (megaparsec)
  → Module.hs      モジュールロード・名前解決
  → Typechecker.hs 型チェック・エフェクト検証
  → Lowering.hs    AST → Thread ベース IR (v0.2)
  → Emit.hs        IR → KTRI バイナリフォーマット
```

### 3.1 Lexer (トークン化)

megaparsec ベースの字句解析器。行末トークンが識別子・リテラル・`}`・`)`・`]`・`break`・`return`・`reply`・`next` 等であり、かつ次行先頭が `.`・`)`・`]`・`}`・`case`・`else`・`finally`・`of` でない場合、改行位置にセミコロンを自動挿入する。

### 3.2 Parser (構文解析)

megaparsec を用いて AST を生成する。式・文・宣言の完全な構文解析を行う。

### 3.3 Module (モジュール解決)

モジュールのロードと名前解決を担当する。

### 3.4 Typechecker (型チェック)

型チェックとエフェクト検証を行う。型システムの詳細は [02-type-system.md](02-type-system.md) を参照。

### 3.5 Lowering (IR 変換)

AST を Thread ベースの IR に変換する。各ブロック (agent 本体・handle 本体・for 本体・par 分岐など) が独立した Thread となる。

### 3.6 Emit (バイナリ出力)

IR を KTRI バイナリフォーマットに変換する。フォーマット仕様は [04-binary-format.md](04-binary-format.md) を参照。

---

## 4. 用語集

### Agent

KATARI の基本的な計算単位。`agent` キーワードで宣言される。パラメータ・戻り値型・オプションのエフェクト注釈を持つ。子 agent の spawn、request の発行、effect の handle が可能。ソースコードでは `AgentDecl` (宣言)、IR では `IRAgentDef` (定義)、プロトコル上では `agent_def_id` (定義の識別子) として表現される。

### Request

操作の宣言。抽象メソッドに類似する。`request` キーワードで宣言され、handler がその実装を提供する。子 agent が request を発行すると、直接の親 agent が handle する。対応する handler がない場合はさらに上位の agent に転送される。

### Handle

request handler をインストールする文。オプションで状態変数 (state variable) を持つ。`handle` 文の位置から囲むブロックの末尾までがそのスコープとなる。state 変数の初期値・request case・return case を含む。

### Thread

IR レベルの実行単位。各ブロックが独立した Thread となる。以下の 7 種類の ThreadKind が存在する:

| ThreadKind | 説明 |
|---|---|
| `FN_BODY` | agent 本体 |
| `BLOCK` | 一般ブロック |
| `HANDLER_TARGET` | handle のスコープ本体 |
| `REQUEST_HANDLER` | request case の処理本体 |
| `HANDLE_THEN` | handle の return case |
| `FOR_BODY` | for ループ本体 |
| `FOR_THEN` | for の finally ブロック |

### Signal

IR レベルの制御フロー機構。以下の種類がある:

| Signal | 命令 | 説明 |
|---|---|---|
| Normal | `IComplete` | ブロックの正常完了 |
| FnReturn | `IReturn` | agent からの return |
| HandleBreak | `IHandleBreak` | handle スコープからの脱出 |
| Continue | `IContinue` | 次の処理への継続 |
| ForBreak | `IForBreak` | for ループからの脱出 |
| ForContinue | `IForContinue` | for ループの次の反復への継続 |

### Scope chain

子 Thread は親の変数にグローバル一意の VarId を通じてアクセスできる。ただし ICall はコンテキスト境界を形成し、呼び出し先の agent は新しいスコープで開始される。

### Suspension point (中断点)

実行が yield する地点。ICall・IPar・IRequest の 3 種類がある。中断点で request キューが処理される。

### NameTable

デバッグ専用のメタデータ。VarId・AgentId・RequestId を人間可読な名前にマッピングする。KTRI バイナリには含まれない。

---

## 5. ビルドと実行

```sh
# Haskell ビルド
just build-hs              # 全 Haskell パッケージ
just build-compiler        # コンパイラのみ
just build-cli             # CLI のみ

# コンパイル・ダンプ
stack exec katari -- compile <file.ktr> -o <file.ktri>
stack exec katari -- dump <file.ktr>   # IR をテキストダンプ

# Rust ランタイム
just build-rust
just run-runtime <args>
```

---

## 6. 仕様書索引

| ファイル | 内容 |
|---|---|
| [00-overview.md](00-overview.md) | 本文書 — 言語概要 |
| [01-language.md](01-language.md) | 構文とセマンティクス |
| [02-type-system.md](02-type-system.md) | 型システム |
| [03-ir.md](03-ir.md) | IR 仕様 (v0.2) |
| [04-binary-format.md](04-binary-format.md) | KTRI バイナリフォーマット |
| [05-runtime.md](05-runtime.md) | ランタイム実行モデル |
| [06-protocol.md](06-protocol.md) | Katari Protocol |
| [07-servers.md](07-servers.md) | サーバー仕様 |
