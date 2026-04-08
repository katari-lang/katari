# 外部サーバー実装

spec 参照: `07-katari-protocol.md`, `10-servers.md`

全外部サーバーは Katari Protocol を実装した独立プロセス (Rust/axum)。
各サーバーの katari base URL は `katari_config.yaml` で登録される。

---

## 共通実装

各外部サーバーは以下を実装する:

```
GET  /task      → サーバーが提供する task 定義一覧 (JSON Schema 付き)
GET  /request   → サーバーが提供する request 定義一覧 (JSON Schema 付き)
POST /agent     → task 実行開始 (agent 生成)
POST /agent/request  → request 受け取り
POST /agent/reply    → reply 送信
POST /agent/return   → 完了通知
POST /agent/terminate     → 停止指示
POST /agent/terminate_ack → 停止確認
```

外部サーバーの task は KATARI 実行環境 (agent ツリー) には属さず、
runtime server が `POST /agent` を送信することで実行開始される。

---

## 1. Cron Server

**役割**: スケジューリング機能の提供

**tasks**:
```
schedule(cron_expr: string) -> null with notify
  cron 式で定期実行。トリガー毎に notify request を発行。

schedule_once(at: string) -> null with notify
  ISO 8601 絶対時刻で 1 回だけ実行。トリガー時に notify request を発行。

interval(duration_ms: integer) -> null with notify
  現在時刻基準で一定間隔。トリガー毎に notify request を発行。

delay(duration_ms: integer) -> null
  一定時間後に完了 (notify なし)。

now() -> string
  現在時刻を ISO 8601 文字列で返す。
```

**requests**:
```
notify(time: string) -> null
  スケジュールがトリガーされた時刻 (ISO 8601) を引数として発行。
```

**実装ポイント**:
- `schedule` / `schedule_once` / `interval`: タイマー管理 (tokio::time)
- notify 発行タイミングで `POST /agent/request` を親エージェントに送信
- delay: `tokio::time::sleep` 後に完了

---

## 2. AI Server

**役割**: LLM (Claude 等) へのアクセス提供

**tasks**:
```
ai(prompt: string, thread_id: string | null, system: string | null) -> string
  単一ターン問答。thread_id でスレッドを継続できる。

ai_stream_task(prompt: string, thread_id: string | null, system: string | null) -> string with ai_stream
  ストリーミング応答。チャンクごとに ai_stream request を発行。
  最終的な完全テキストを返す。

ai_structured(prompt: string, schema: string, thread_id: string | null, system: string | null) -> string
  JSON Schema (string) に従った構造化出力。JSON 文字列を返す。

make_thread() -> string
  会話スレッドを生成し thread_id を返す。
```

**requests**:
```
ai_stream(chunk: string) -> null
  ストリーミング中の各テキストチャンクを引数として発行。
```

**実装ポイント**:
- Anthropic API (または他の LLM API) へのリクエスト
- thread_id: 会話履歴の管理 (DB で保存)
- ai_stream: SSE をチャンクに分解して `POST /agent/request` を順次発行

---

## 3. Discord Server

**役割**: Discord ボット機能の提供

**tasks**:
```
listen(channel_id: string | null, guild_id: string | null) -> null with on_message | on_reaction
  指定チャンネル (null なら全チャンネル) のイベントを監視。
  メッセージ受信時に on_message、リアクション追加時に on_reaction を発行。

send_message(channel_id: string, content: string) -> string
  メッセージを送信。返り値は message_id。

send_embed(channel_id: string, embed: object) -> string
  リッチ埋め込みメッセージを送信。返り値は message_id。

add_reaction(channel_id: string, message_id: string, emoji: string) -> null
  メッセージにリアクションを追加。
```

**requests**:
```
on_message({ channel_id: string, author_id: string, content: string, guild_id: string }) -> null
  メッセージ受信時に発行。

on_reaction({ message_id: string, channel_id: string, user_id: string, emoji: string }) -> null
  リアクション追加時に発行。
```

**実装ポイント**:
- Discord Gateway (WebSocket) でイベント受信
- 環境変数 `DISCORD_BOT_TOKEN` から認証情報を取得
- `listen` task はイベントループで待機; 各イベントで `POST /agent/request` を親に送信

---

## 4. Sandbox Server

**役割**: 分離された実行環境 (Docker コンテナ) の提供

**tasks**:
```
create_sandbox() -> string
  Docker コンテナを生成し sandbox_id を返す。

destroy_sandbox(sandbox_id: string) -> null
  コンテナを停止・削除。

exec(sandbox_id: string, cmd: string, timeout_ms: integer) -> { stdout: string, stderr: string, exit_code: integer }
  コンテナ内でコマンドを実行。

exec_with_stdin(sandbox_id: string, cmd: string, stdin: string, timeout_ms: integer) -> { stdout: string, stderr: string, exit_code: integer }
  標準入力付きでコマンドを実行。

write_file(sandbox_id: string, path: string, content: string) -> null
  コンテナ内のファイルに書き込む。

read_file(sandbox_id: string, path: string) -> string
  コンテナ内のファイルを読み込む。
```

**実装ポイント**:
- Docker Engine API (bollard 等) でコンテナを操作
- create_sandbox: `docker create` + `docker start`
- exec: `docker exec` で任意コマンド実行、stdout/stderr/exit_code を取得
- タイムアウト: timeout_ms を超えたら強制終了
- sandbox_id: コンテナ ID をそのまま使用
- セキュリティ: コンテナはネットワーク隔離・リソース制限付き (CPU, メモリ)
