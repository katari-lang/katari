# KATARI 実装概要

## コンポーネント構成

```
katari/
├── compiler/      Haskell  ソース → IR バイナリ生成
├── cli/           Haskell  katari コマンドラインツール
├── runtime/       Rust     IR 実行 + Katari Protocol サーバー
├── cron-server/   Rust     Cron 外部サーバー
├── ai-server/     Rust     AI 外部サーバー
├── discord-server/ Rust    Discord 外部サーバー
└── sandbox-server/ Rust    Sandbox 外部サーバー
```

## コンパイルパイプライン

```
Source (.ktr)
  ↓  Lexer     トークン列生成・セミコロン自動挿入
  ↓  Parser    AST (SrcSpan 付き) 生成
  ↓  Resolver  名前解決・インポート展開・モジュール依存順序確認
  ↓  Typechecker  NormalizedType ベース型推論・部分型チェック・消尽性チェック
  ↓  Lowering  AST → IR (フラット命令列) 変換
  ↓  Emit      IR バイナリ生成 ("KTRI" フォーマット)
```

## ランタイムコンポーネント

```
Runtime Server (Rust/axum)
  ├── IR Loader        バイナリ読み込み・Task/Request テーブル構築
  ├── Agent Manager    Agent ライフサイクル管理 (生成・実行・終了)
  ├── Interpreter      フラット命令列の協調イベントループ実行
  ├── Request Router   親ベースルーティング・プロキシモード
  └── Katari Protocol  REST エンドポイント群 (POST /agent 等)
```

## 設計上の主要決定

| 決定 | 内容 |
|---|---|
| IR は フラット命令列 | 基本ブロック分割なし。1 task = 1 コルーチン |
| 値は JSON 互換 | null, integer, number, boolean, string, array, object のみ。クロージャなし |
| 協調イベントループ | yield 点 (ICall, IPar, IRequest) のみでキューチェック |
| 完全非再入 | 1 エージェント = 同時実行ハンドラ最大 1 つ |
| 親ベースルーティング | request は常に直接の親へ。handler なければ親の親へ転送 (プロキシ) |
| 永続化 | yield 点で AgentState を JSON シリアライズ可能 |

## ファイル拡張子・設定

- ソースファイル: `.ktr`
- IR バイナリ: `.ktri` (magic: `KTRI`, version 2 bytes)
- 設定ファイル: `katari_config.yaml`
