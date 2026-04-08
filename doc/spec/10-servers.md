# KATARI Language Specification - Server Specifications

## 概要

KATARI の分散実行環境は、Katari Protocol を実装した複数のサーバーで構成される。各サーバーは独自の task と request を提供し、相互に連携して動作する。

全サーバーは docker-compose で管理される。

## サーバーの共通仕様

全サーバーは以下を満たす:

1. Katari Protocol のエンドポイントを katari base URL 以下に提供する (→ [07-katari-protocol.md](07-katari-protocol.md))
2. `GET /task` で提供する task 一覧を返す
3. `GET /request` で提供する request 一覧を返す
4. `POST /agent` で agent を生成・実行可能
5. agent のライフサイクル管理 (request, reply, terminate, return, terminate_ack)

## Runtime Server

### 役割

KATARI 言語で記述されたコードを実行するサーバー。コンパイルされた IR を読み込み、解釈実行する。Runtime は Docker プロセスとして動作し、コンパイルは外部で行われる。

### 追加エンドポイント

Katari Protocol エンドポイント (katari base URL 以下) に加え、サーバーのトップレベルに以下を提供:

#### POST /apply

コンパイル済み IR バイナリを runtime に適用 (デプロイ) する。

**Request:**

```json
{
  "ir_binary": "base64 encoded binary"
}
```

- `ir_binary`: コンパイル済み IR バイナリ。

**Response:**

```json
{
  "success": true,
  "modules": ["main", "lib.cron", "lib.ai"],
  "tasks": 12,
  "requests": 5
}
```

#### POST /run

外部 (Katari Protocol 外) からの task 実行リクエスト。

**Request:**

```json
{
  "task_name": "string",
  "args": ["any"]
}
```

- `task_name`: 実行する task の名前 (修飾名)。
- `args`: 引数。

**Response:**

```json
{
  "agent_id": "string",
  "status": "running"
}
```

#### GET /run/:agent_id

実行結果の取得。

**Response:**

```json
{
  "agent_id": "string",
  "status": "running | completed | error",
  "result": "any (when completed)",
  "error": "string (when error)"
}
```

#### GET /run

現在実行中のタスク一覧を取得する。

**Response:**

```json
[
  {
    "agent_id": "string",
    "task_name": "string",
    "status": "running | completed | error"
  }
]
```

### 提供する task / request

- `GET /task`: `external` 以外の全ての `task` 定義を返す。
- `GET /request`: `external` 以外の全ての `request` 定義を返す。

### 内部動作

- IR の各タスクを管理
- タスク呼び出しは子 agent を `POST /agent` で spawn する
- 外部タスク呼び出しは対応サーバーの `POST /agent` に POST する
- request perform は提供された handle ブロック / handle パラメータから handler の agent に request を送る
- `ICall` は子 agent を spawn し完了を待機する。`IPar` は複数の子 agent を並行 spawn し全完了を待機する
- handle パラメータは agent 内で管理し、request の queue 処理で更新する
- TaskId ↔ QualifiedName の NameTable をデバッグ用に保持する

### 設定

```yaml
# katari_config.yaml
runtime:
  port: 8000
  katari_endpoint: "http://runtime:8000/katari"
```

---

## Cron Server

### 役割

定期実行 (cron) に関する task と request を提供するサーバー。

### 提供する Request

#### notify

```
request notify(time: string) -> null
```

スケジュールされた時刻に達した際に発行される request。`time` は ISO 8601 形式のタイムスタンプ。

### 提供する Task

#### schedule

```
task schedule(cron_expression: string) -> null with notify
```

cron 形式の文字列に基づいてスケジュールを設定し、設定された各時刻に `notify` request を発行する。

- `cron_expression`: 標準 cron 形式 (例: `"0 0 * * *"` = 毎日 0 時)
- スケジュールに達するたびに `notify` request が親に送られる
- 親の handler が `reply` すると次のスケジュールを待つ
- 親の handler が `break` するとスケジュールを停止して return

#### schedule_once

```
task schedule_once(at: string) -> null with notify
```

指定時刻に一度だけ `notify` を発行する。

- `at`: ISO 8601 形式のタイムスタンプ

#### interval

```
task interval(duration_ms: integer) -> null with notify
```

現在時刻から指定ミリ秒間隔で繰り返し `notify` request を発行する。

- `duration_ms`: 間隔 (ミリ秒)
- 各間隔に達するたびに `notify` request が親に送られる
- 親の handler が `reply` すると次の間隔を待つ
- 親の handler が `break` すると繰り返しを停止して return

#### delay

```
task delay(duration_ms: integer) -> null
```

指定ミリ秒間待機する。request を発行しない。

#### now

```
task now() -> string
```

現在時刻を ISO 8601 形式の文字列で返す。

### KATARI 側の宣言例

```katari
// lib/cron.ktr
@"スケジュール時刻の通知"
external request notify(time: string) -> null from "cron_server:notify"

@"cron スケジュール設定"
external task schedule(cron_expression: string) -> null with notify from "cron_server:schedule"

@"一回限りのスケジュール"
external task schedule_once(at: string) -> null with notify from "cron_server:schedule_once"

@"一定間隔で繰り返し通知"
external task interval(duration_ms: integer) -> null with notify from "cron_server:interval"

@"指定時間待機"
external task delay(duration_ms: integer) -> null from "cron_server:delay"

@"現在時刻を取得"
external task now() -> string from "cron_server:now"
```

### 設定

```yaml
# katari_config.yaml
external_katari_endpoints:
  cron_server: "http://cron:8000/katari"
```

---

## AI Server

### 役割

AI/LLM に関する task と request を提供するサーバー。

### 提供する Request

#### ai_stream

```
request ai_stream(chunk: string) -> null
```

AI のストリーミング応答の各チャンクを発行する request。

### 提供する Task

#### ai

```
task ai(prompt: string, thread_id: string | null, system: string | null) -> string
```

AI に質問し、回答を得る。

- `prompt`: ユーザーのプロンプト
- `thread_id`: 会話スレッド ID。`null` の場合は新規会話。
- `system`: システムプロンプト。`null` の場合はデフォルト。
- 戻り値: AI の回答テキスト

#### ai_stream_task

```
task ai_stream_task(prompt: string, thread_id: string | null, system: string | null) -> string with ai_stream
```

AI にストリーミングで質問する。各チャンクが `ai_stream` request として発行される。最終的な完全な回答が戻り値。

#### ai_structured

```
task ai_structured(prompt: string, schema: string, thread_id: string | null, system: string | null) -> string
```

AI に構造化された出力を要求する。`schema` は JSON Schema の文字列表現。戻り値は JSON 文字列。

#### make_thread

```
task make_thread() -> string
```

会話スレッドを作成する。戻り値はスレッド ID。

### KATARI 側の宣言例

```katari
// lib/ai.ktr
@"AIストリーミングチャンク"
external request ai_stream(chunk: string) -> null from "ai_server:ai_stream"

@"AIに質問する"
external task ai(prompt: string, thread_id: string | null, system: string | null) -> string from "ai_server:ai"

@"AIにストリーミングで質問する"
external task ai_stream_task(prompt: string, thread_id: string | null, system: string | null) -> string with ai_stream from "ai_server:ai_stream_task"

@"AIに構造化出力を要求する"
external task ai_structured(prompt: string, schema: string, thread_id: string | null, system: string | null) -> string from "ai_server:ai_structured"

@"会話スレッドを作成する"
external task make_thread() -> string from "ai_server:make_thread"
```

### 設定

```yaml
external_katari_endpoints:
  ai_server: "http://ai:8000/katari"
```

---

## Discord Wrapper Server

### 役割

Discord Bot に関する task と request を提供するサーバー。

### 提供する Request

#### on_message

```
request on_message(message: {
  channel_id: string,
  author_id: string,
  content: string,
  guild_id: string
}) -> null
```

Discord でメッセージが投稿された際に発行される request。

#### on_reaction

```
request on_reaction(reaction: {
  message_id: string,
  channel_id: string,
  user_id: string,
  emoji: string
}) -> null
```

リアクションが追加された際に発行される request。

### 提供する Task

#### listen

```
task listen(channel_id: string | null, guild_id: string | null) -> null with on_message | on_reaction
```

Discord のイベントを listen する。フィルタ条件を指定可能。`null` の場合は全てのイベントを受信する。

- handler が `reply` すると次のイベントを待つ
- handler が `break` すると listen を停止

#### send_message

```
task send_message(channel_id: string, content: string) -> string
```

メッセージを送信する。戻り値はメッセージ ID。

#### send_embed

```
task send_embed(channel_id: string, embed: {
  title: string | null,
  description: string | null,
  color: integer | null,
  fields: array[{name: string, value: string, inline: boolean | null}] | null
}) -> string
```

Embed メッセージを送信する。

#### add_reaction

```
task add_reaction(channel_id: string, message_id: string, emoji: string) -> null
```

メッセージにリアクションを追加する。

### KATARI 側の宣言例

```katari
// lib/discord.ktr
@"メッセージ受信イベント"
external request on_message(message: {
  channel_id: string @ "チャンネルID"
  author_id: string @ "送信者ID"
  content: string @ "メッセージ内容"
  guild_id: string @ "サーバーID"
}) -> null from "discord_server:on_message"

@"Discordイベントをlistenする"
external task listen(channel_id: string | null, guild_id: string | null) -> null with on_message | on_reaction from "discord_server:listen"

@"メッセージを送信する"
external task send_message(channel_id: string, content: string) -> string from "discord_server:send_message"

@"Embedメッセージを送信する"
external task send_embed(channel_id: string, embed: {
  title: string | null @ "タイトル"
  description: string | null @ "説明"
  color: integer | null @ "色"
  fields: array[{name: string, value: string, inline: boolean | null}] | null @ "フィールド"
}) -> string from "discord_server:send_embed"
```

### 設定

```yaml
external_katari_endpoints:
  discord_server: "http://discord:8000/katari"
```

---

## Sandbox Server

### 役割

セキュアな環境でのコマンド実行を提供するサーバー。隔離された Docker コンテナ内でコマンドを実行する。

### 提供する Task

#### create_sandbox

```
task create_sandbox() -> string
```

サンドボックス (Docker コンテナ) を作成する。戻り値はサンドボックス ID。

#### destroy_sandbox

```
task destroy_sandbox(sandbox_id: string) -> null
```

サンドボックスを破棄する。

#### exec

```
task exec(sandbox_id: string, command: string, timeout_ms: integer | null) -> {
  stdout: string,
  stderr: string,
  exit_code: integer
}
```

コマンドを実行する。

- `sandbox_id`: 対象サンドボックスの ID
- `command`: 実行するコマンド (shell 経由)
- `timeout_ms`: タイムアウト (ミリ秒)。`null` の場合はデフォルト 30000。
- 戻り値: stdout, stderr, exit_code

#### exec_with_stdin

```
task exec_with_stdin(sandbox_id: string, command: string, stdin: string, timeout_ms: integer | null) -> {
  stdout: string,
  stderr: string,
  exit_code: integer
}
```

stdin 付きでコマンドを実行する。

#### write_file

```
task write_file(sandbox_id: string, path: string, content: string) -> null
```

サンドボックス内にファイルを書き込む。

#### read_file

```
task read_file(sandbox_id: string, path: string) -> string
```

サンドボックス内のファイルを読む。

### KATARI 側の宣言例

```katari
// lib/sandbox.ktr
@"サンドボックスを作成する"
external task create_sandbox() -> string from "sandbox_server:create_sandbox"

@"サンドボックスを破棄する"
external task destroy_sandbox(sandbox_id: string) -> null from "sandbox_server:destroy_sandbox"

@"コマンドを実行する"
external task exec(sandbox_id: string, command: string, timeout_ms: integer | null) -> {
  stdout: string @ "標準出力"
  stderr: string @ "標準エラー出力"
  exit_code: integer @ "終了コード"
} from "sandbox_server:exec"

@"stdin付きでコマンドを実行する"
external task exec_with_stdin(sandbox_id: string, command: string, stdin: string, timeout_ms: integer | null) -> {
  stdout: string @ "標準出力"
  stderr: string @ "標準エラー出力"
  exit_code: integer @ "終了コード"
} from "sandbox_server:exec_with_stdin"

@"ファイルを書き込む"
external task write_file(sandbox_id: string, path: string, content: string) -> null from "sandbox_server:write_file"

@"ファイルを読む"
external task read_file(sandbox_id: string, path: string) -> string from "sandbox_server:read_file"
```

### 設定

```yaml
external_katari_endpoints:
  sandbox_server: "http://sandbox:8000/katari"
```

---

## Docker Compose 構成例

```yaml
version: "3"
services:
  runtime:
    image: katari-runtime:latest
    ports:
      - "8000:8000"
    volumes:
      - ./katari_config.yaml:/app/katari_config.yaml

  cron:
    image: katari-cron:latest
    ports:
      - "8001:8000"

  ai:
    image: katari-ai:latest
    ports:
      - "8002:8000"
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}

  discord:
    image: katari-discord:latest
    ports:
      - "8003:8000"
    environment:
      - DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}

  sandbox:
    image: katari-sandbox:latest
    ports:
      - "8004:8000"
    privileged: true # Docker-in-Docker for isolation
```

## サーバーの仮想モジュール

runtime 以外のサーバーは明示的なモジュールシステムを持たないが、`GET /task` と `GET /request` の `name` フィールドでモジュール風の名前空間を使用可能:

- `cron_server:schedule` → name: `schedule`
- `cron_server:cron.schedule` → name: `cron.schedule` (仮想モジュール `cron`)

これにより、KATARI のモジュールシステムとの親和性を保つ。
