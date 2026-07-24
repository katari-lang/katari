---
title: "Katari — AI エージェントのオーケストレーションを書く言語 (v0.1.0)"
emoji: "🗣️"
type: "tech"
topics: ["ai", "agent", "言語処理系", "effectsystem", "mcp"]
published: false
---

<!-- DRAFT — yukikurage レビュー用。公開前 TODO: リポジトリ URL、文体最終調整 -->

AI エージェントのオーケストレーションを書くための言語 **Katari** を開発しています。v0.1.0 を公開しました。

- Katari ソースはコンパイラ (Haskell) が IR にコンパイルし、常駐 runtime (TypeScript) が実行します
- 実行状態は永続化されます。runtime を再起動しても、実行中のワークフローは続きから再開します
- 「1 週間 sleep する」「毎朝 cron で起きる」「人間の承認を待って止まる」を、そのままコードとして書けます

この記事では、何がどう書けるのかを順に紹介します。

## ワークフローを書く

Katari の関数は `agent` です。次のプログラムは、毎週月曜 9:00 に処理を実行し続けるワークフローです。

```katari
@"Every Monday 09:00 JST, post the weekly digest."
agent main() -> never {
  use discord.provider(source = credentials.env(key = "DISCORD_TOKEN"))
  agent tick(time: number) -> null {
    discord.try_send(channel = "123456789", text = build_digest())
  }
  time.watch(
    schedule = time.cron(expression = "0 9 * * 1", timezone = "Asia/Tokyo"),
    deliver_to = tick,
  )
}
```

`time.watch` の次回発火時刻は runtime 側に永続化されます。runtime を再起動してもスケジュールは維持され、停止中に過ぎた発火は復旧時に 1 回だけ実行されます。同様に `time.sleep(milliseconds = 7 * 24 * 3600 * 1000)` と書けば 1 週間後に続きが実行されます。プロセスの生存とワークフローの生存が切り離されているのが、この runtime の役割です。

時刻の取得 (`time.now()`) も runtime への呼び出しです。取得した値は観測した処理と一緒に永続化されるため、リトライや再起動時の replay で値が変わることはありません。

## AI にツールを渡す

`agent` はそのまま AI のツールになります。docstring (`@"..."`) と型シグネチャからツールスキーマが導出されるので、スキーマ定義を別に書くことはありません。

```katari
@"Tool: search the web and return the top results as a compact digest."
agent search(@"The search query." query: string) -> string {
  tavily.digest(query = query)
}

agent answer(question: string) -> string {
  ai.infer_with_tools(
    history = [types.turn(role = "user", text = question)],
    tools = [search, web.fetch_page, e2b.run_python],
    max_steps = 8,
  )
}
```

`ai.infer_with_tools` はツール呼び出しループです。モデルが要求したツール呼び出しは並列に実行され、引数はツールのスキーマで検証され、ツールの失敗 (throw / panic / タイムアウト) はループを壊さずエラー結果としてモデルに返ります。モデルプロバイダは handler として注入します:

```katari
use anthropic.provider(model = "claude-sonnet-5", source = credentials.env(key = "CLAUDE_API_KEY"))
```

`gemini.provider` / `openai.provider` に差し替えても、ループとツールのコードは変わりません。プロバイダとループの間の接点は「1 ステップ推論する」という request 1 つだけです。

## effect と handler

上の `use ...provider` は、Katari の中心機構である effect system の使い方の一例です。能力は `request` として宣言し、実装は handler が与えます。

```katari
@"Approval before an irreversible action."
request approve(description: string) -> boolean

agent deploy_if_approved() -> string {
  if (approve(description = "deploy to production")) {
    run_deploy()
  } else {
    "cancelled"
  }
}
```

`approve` にどう答えるかは呼び出し側の文脈が決めます。Discord のボタンで operator に聞く handler を挟む、テストではつねに true を返す handler を挟む、などが選べます。handler を挟まなかった場合、request は実行の外側に浮上し、管理コンソールや `katari answer` から人間が回答するまでワークフローは停止して待ちます。この「人間への問い合わせで止まって待つ」が言語機構と runtime の永続化の組で成立しているので、承認フローのために外部のワークフローエンジンを併設する必要がありません。

型システムは effect row を追跡します。ある処理がどの request を実行しうるかは型に現れ、handler の被覆はコンパイル時に検査されます。

## MCP との接続

MCP サーバーのツール群は 1 行でプログラムに接続できます。

```katari
let tools : mcp.toolbox[mcp.scope] = use mcp.provide[mcp.scope](
  url = "https://mcp.notion.com/mcp",
  auth = mcp.oauth(name = "notion"),
)
```

取得した `toolbox` の中身はふつうの agent 値なので、そのまま AI のツールリストに混ぜられます。`mcp.oauth` は runtime 管理の OAuth credential を指します。トークンはプログラムに入らず、未認可の場合は実行が認可待ちで停止し、ブラウザでの認可完了後に続きから再開します。

静的に使いたい場合は `katari mcp pull` で型付きバインディングを生成します:

```sh
katari mcp pull --url https://mcp.notion.com/mcp --out src/my_agent/notion.ktr
```

生成後は `notion.notion_create_pages(...)` のように、サーバーのツールを型付きの関数として直接呼べます。

逆方向もあります。`mcp.serve` は自分のプログラムの agent 群を MCP サーバーとして公開します。Katari で書いたワークフローを、外部の AI クライアントのツールにする方向です。

## 並行と常駐

並列はデータの形で書きます:

```katari
let bodies = parallel for (let url in urls) { next web.fetch_page(url = url) }
```

常駐型 (チャットボット、監視エージェント) には `region` — 構造化並行性の nursery — を使います。バックグラウンドの fiber (チャンネルの購読、定期監視) を fork し、fiber からのイベントは 1 箇所 (`region.watch`) に集約され、handler が捌きます。fiber の crash は型付きイベントとして同じ場所に届き、これを扱う handler がないプログラムはコンパイルが通りません。ai パッケージの `serve_observations` と組み合わせると、「イベントを受けてモデルが 1 ターン考え、ツールで応答する」常駐エージェントになります。会話の状態も handler の状態変数として永続化され、再起動を跨ぎます。

## プロジェクトとデプロイ

```sh
katari init my_agent && cd my_agent
katari check                 # 型検査 (effect の被覆検査を含む)
katari apply                 # コンパイルして runtime にスナップショットをデプロイ
katari run my_agent.main --detach
```

パッケージは registry からのスナップショット固定で解決します。`ai` / `discord` / `slack` / `memory` (永続メモリ) / `e2b` (Python サンドボックス) / `tavily` (検索) などを公開しています。TypeScript の FFI サイドカーを持つパッケージ (discord.js クライアント等) も、`katari apply` が依存ごとバンドルします。

## リンク

- ドキュメント: https://katari-lang.dev (MCP でも提供: https://katari-lang.dev/mcp — AI エージェントから直接参照できます)
- リポジトリ: <!-- TODO: 公開 URL -->

v0.1.0 は「趣味プロジェクトを載せて、壊れたら教えてほしい」段階です。感想・issue をお待ちしています。
