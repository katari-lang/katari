# KATARI Language Specification - Server Specifications

## 1. 概要

KATARI の分散実行環境は、Katari Protocol を実装した複数のサーバーで構成される。各サーバーは独自の agent definition と request を提供し、相互に連携して動作する。全サーバーは docker-compose で管理される。

**TODO**: 公開設定 (pub/private) は現時点では未定義。今後 specify する予定。

**TODO**: 外部 API 連携は基本的に wrapper server 経由で external agent として定義するが、wrapper server の自動生成ツールの整備は改善予定。

## 2. サーバーの共通仕様

全サーバーは以下を満たす:

1. Katari Protocol の**全エンドポイント**を katari base URL 以下に提供する ([06-protocol.md](06-protocol.md) 参照)
   - `GET /request`, `GET /agent_def`, `GET /agent`, `GET /agent/:agent_id`
   - `POST /agent`, `POST /agent/request`, `POST /agent/reply`, `POST /agent/terminate`, `POST /agent/return`, `POST /agent/terminate_ack`
   - 全エンドポイントの実装が必須 (サーバー間で全プロトコル操作が可能)
2. `GET /agent_def` で提供する agent definition 一覧を返す
3. `GET /request` で提供する request 一覧を返す
4. `POST /agent` で agent を生成・実行可能
5. agent のライフサイクル管理 (request, reply, terminate, return, terminate_ack)

**TODO**: Katari Protocol 共通実装のライブラリ化を検討中 (各サーバーがボイラープレートを共有できるように)。

---

## 3. Runtime Server

### 3.1 役割

KATARI 言語で記述されたコードを実行するサーバー。コンパイルされた IR を読み込み、解釈実行する。Runtime は Docker プロセスとして動作し、コンパイルは外部で行われる。実行モデルの詳細は [05-runtime.md](05-runtime.md) を参照。

### 3.2 追加エンドポイント

Katari Protocol エンドポイント (katari base URL 以下) に加え、サーバーのトップレベルに以下を提供する。

#### POST /apply

コンパイル済み IR バイナリを runtime に適用 (デプロイ) する。IR バイナリに加え、agent 名から agent_def_id への対応表と JSON Schema を渡す必要がある。これにより `POST /run` で名前指定による agent 実行が可能になる。

**Request:**

```json
{
  "ir_binary": "base64 encoded binary",
  "agents": {
    "main.hello": 0,
    "main.greet": 1
  },
  "schemas": {
    "main.hello.args": [{ "type": "string" }],
    "main.hello.return": { "type": "string" }
  }
}
```

- `ir_binary`: コンパイル済み IR バイナリ (KTRI フォーマット)。バイナリフォーマットの詳細は [04-binary-format.md](04-binary-format.md) を参照。
- `agents`: agent の修飾名から `agent_def_id` (IR 上の ID) への対応表。`POST /run` で名前指定するために必要。
- `schemas` (optional): JSON Schema 情報。キーは `<agent_name>.args` / `<agent_name>.return` 等。`GET /agent_def` や `GET /request` のレスポンスで使用する。

**Response:**

```json
{
  "ok": true,
  "module_name": "main",
  "agents": [
    { "id": 0, "name": "main.hello" },
    { "id": 1, "name": "main.greet" }
  ],
  "requests": [{ "id": 0, "name": "main.notify" }]
}
```

- `module_name`: ロードされたモジュール名。
- `agents`: ロードされた agent definition の一覧 (ID と名前)。
- `requests`: ロードされた request 定義の一覧。

#### POST /run

外部 (Katari Protocol 外) からの agent 実行リクエスト。以下の手順で実行する:

1. **root agent を作成する** — 名前だけ持つダミーの親 agent (IR コードなし)。外部リクエストの発行元として機能する。
2. **対象 agent を子として spawn する** — root agent の子として、指定された agent definition のインスタンスを生成し実行する。
3. **結果を返す** — 対象 agent が完了した場合は結果を含め、実行中であれば `running` ステータスを返す。

**Request:**

```json
{
  "agent_name": "string",
  "args": ["any"]
}
```

- `agent_name`: 実行する agent definition の名前 (修飾名)。`POST /apply` の `agents` マップに含まれている必要がある。
- `args`: 引数。

**Response:**

```json
{
  "ok": true,
  "agent_id": "string",
  "status": "running | completed | error",
  "result": "any (when completed)",
  "error": "string (when error)"
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

ロード済みモジュール内の利用可能な agent definition と request の一覧を返す。また、現在実行中の agent の状態も返す。

**Response:**

```json
{
  "agent_defs": [
    {
      "name": "string",
      "description": "string",
      "arg_types": ["JSON Schema"],
      "return_type": "JSON Schema",
      "with_effects": ["string"]
    }
  ],
  "requests": [
    {
      "name": "string",
      "description": "string",
      "arg_types": ["JSON Schema"],
      "return_type": "JSON Schema"
    }
  ],
  "running_agents": [
    {
      "agent_id": "string",
      "agent_name": "string",
      "status": "running | completed | error"
    }
  ]
}
```

### 3.3 提供する agent definition / request

- `GET /agent_def`: `external` 以外の全ての agent definition を返す。
- `GET /request`: `external` 以外の全ての request 定義を返す。

### 3.4 内部動作

- IR の各 agent definition を管理する
- agent 呼び出しは子 agent を `POST /agent` で spawn する
- 外部 agent 呼び出しは対応サーバーの `POST /agent` に POST する
- request perform は提供された handle block / handle パラメータから handler の agent に request を送る
- `ICall` は子 agent を spawn し完了を待機する。`IPar` は複数の子 agent を並行 spawn し全完了を待機する
- handle パラメータは agent 内で管理し、request の queue 処理で更新する
- AgentId <-> QualifiedName の NameTable をデバッグ用に保持する

### 3.5 設定

```yaml
# katari_config.yaml
runtime:
  port: 8000
  katari_endpoint: "http://runtime:8000/katari"
```

---

## 4. Cron Server

### 4.1 役割

定期実行 (cron) に関する agent definition と request を提供するサーバー。

### 4.2 提供する Request

#### notify

```
request notify(time: string) -> null
```

スケジュールされた時刻に達した際に発行される request。`time` は ISO 8601 形式のタイムスタンプ。

### 4.3 提供する Agent Definition

#### schedule

```
agent schedule(cron_expression: string) -> null with notify
```

cron 形式の文字列に基づいてスケジュールを設定し、設定された各時刻に `notify` request を発行する。

- `cron_expression`: 標準 cron 形式 (例: `"0 0 * * *"` = 毎日 0 時)
- スケジュールに達するたびに `notify` request が親に送られる
- 親の handler が `continue` すると次のスケジュールを待つ
- 親の handler が `break` するとスケジュールを停止して return

#### schedule_once

```
agent schedule_once(at: string) -> null with notify
```

指定時刻に一度だけ `notify` を発行する。

- `at`: ISO 8601 形式のタイムスタンプ

#### interval

```
agent interval(duration_ms: integer) -> null with notify
```

現在時刻から指定ミリ秒間隔で繰り返し `notify` request を発行する。

- `duration_ms`: 間隔 (ミリ秒)
- 各間隔に達するたびに `notify` request が親に送られる
- 親の handler が `continue` すると次の間隔を待つ
- 親の handler が `break` すると繰り返しを停止して return

#### delay

```
agent delay(duration_ms: integer) -> null
```

指定ミリ秒間待機する。request を発行しない。

#### now

```
agent now() -> string
```

現在時刻を ISO 8601 形式の文字列で返す。

### 4.4 KATARI 側の宣言例

```katari
// lib/cron.ktr
@"スケジュール時刻の通知"
external request notify(time: string) -> null from "cron_server:notify"

@"cron スケジュール設定"
external agent schedule(cron_expression: string) -> null with notify from "cron_server:schedule"

@"一回限りのスケジュール"
external agent schedule_once(at: string) -> null with notify from "cron_server:schedule_once"

@"一定間隔で繰り返し通知"
external agent interval(duration_ms: integer) -> null with notify from "cron_server:interval"

@"指定時間待機"
external agent delay(duration_ms: integer) -> null from "cron_server:delay"

@"現在時刻を取得"
external agent now() -> string from "cron_server:now"
```

### 4.5 設定

```yaml
# katari.toml
external_katari_endpoints:
  cron_server: "http://cron:8000/katari"
```

---

## 5. AI Server

### 5.1 役割

AI/LLM に関する agent definition と request を提供するサーバー。KATARI の agent が AI に処理を委譲し、AI が自律的に他の agent を呼び出せる仕組みを提供する。

### 5.2 提供する Request

#### ai_stream

```
request ai_stream(chunk: string) -> null
```

AI のストリーミング応答の各チャンクを発行する request。

### 5.3 提供する Agent Definition

#### ai

```
agent ai(prompt: string, thread_id: string | null, system: string | null) -> string
```

AI に質問し、回答を得る。

- `prompt`: ユーザーのプロンプト
- `thread_id`: 会話スレッド ID。`null` の場合は新規会話。
- `system`: システムプロンプト。`null` の場合はデフォルト。
- 戻り値: AI の回答テキスト

#### ai_stream_agent

```
agent ai_stream_agent(prompt: string, thread_id: string | null, system: string | null) -> string with ai_stream
```

AI にストリーミングで質問する。各チャンクが `ai_stream` request として発行される。最終的な完全な回答が戻り値。

#### ai_structured

```
agent ai_structured(prompt: string, schema: string, thread_id: string | null, system: string | null) -> string
```

AI に構造化された出力を要求する。`schema` は JSON Schema の文字列表現。戻り値は JSON 文字列。

- `prompt`: ユーザーのプロンプト
- `schema`: 出力の JSON Schema (文字列表現)
- `thread_id`: 会話スレッド ID。`null` の場合は新規会話。
- `system`: システムプロンプト。`null` の場合はデフォルト。
- 戻り値: JSON Schema に準拠した JSON 文字列

#### make_thread

```
agent make_thread() -> string
```

会話スレッドを作成する。戻り値はスレッド ID。

### 5.4 Agent 動作 (AI tool call の仕組み)

AI server は `POST /agent` を受け取った際、以下の手順で動作する。

#### 5.4.1 Tool の登録

- `with_effects` リスト (spawn 時に親から渡された) を参照し、各 request の JSON Schema を `GET /request` で取得済みのものから検索する。
- それらの request を「request tool」として AI に登録する。

#### 5.4.2 Agent Definition ツールのフィルタリング

- `RUNTIME_KATARI_ENDPOINT` (環境変数) の `GET /agent_def` から runtime の agent definition 一覧を取得する。
- 各 agent definition について、その `with_effects` (agent definition が発生させる可能性のある request 集合) が、spawn 時に渡された `with_effects` (現コンテキストで handle 可能な request 集合) に**完全に含まれる**場合のみ、「agent tool」として AI に提供する。
  - `agent_def.with_effects` が `spawn.with_effects` の部分集合である場合のみ提供
  - この計算は AI server 内で決定的に行う

#### 5.4.3 AI の実行

- 登録した tool (request tool + agent tool) と、spawn 時の `call_stack` を system prompt として AI に渡す。
- AI が tool call を行うと、以下のように処理する:

**request tool の場合**:
AI が tool call -> AI server が `parent_agent_where` の `POST /agent/request` にリクエストを送信 -> reply を受け取り AI に返す。

**agent tool の場合**:
AI が tool call -> AI server が `RUNTIME_KATARI_ENDPOINT` の `POST /agent` に直接 spawn する (AI server の agent が親となる) -> 完了を待って AI に結果を返す。

#### 5.4.4 Handler Proxy

AI server の agent は Katari Protocol の全エンドポイントを実装しているため、自身が spawn した子 agent (agent tool で起動した agent) から request が飛んできた場合、以下のように処理する:

- 自身が handle できる request (= `with_effects` に含まれる) の場合: その request を `parent_agent_where` の `POST /agent/request` に転送 (proxy) し、reply を受け取って子 agent に転送する。
- handle できない request の場合: エラーとして処理する (型チェックが通っていれば発生しない)。

**Future plan**: AI 自身が handler block を定義できるようにする (現時点では proxy のみ)。

#### 5.4.5 call_stack による無限再帰防止

spawn 時に受け取った `call_stack` を system prompt として AI に渡すことで、AI が同じ agent を再帰的に呼び出し続けることを防ぐ。

### 5.5 KATARI 側の宣言例

```katari
// lib/ai.ktr
@"AI ストリーミングチャンク"
external request ai_stream(chunk: string) -> null from "ai_server:ai_stream"

@"AI に質問する"
external agent ai(prompt: string, thread_id: string | null, system: string | null) -> string from "ai_server:ai"

@"AI にストリーミングで質問する"
external agent ai_stream_agent(prompt: string, thread_id: string | null, system: string | null) -> string with ai_stream from "ai_server:ai_stream_agent"

@"AI に構造化出力を要求する"
external agent ai_structured(prompt: string, schema: string, thread_id: string | null, system: string | null) -> string from "ai_server:ai_structured"

@"会話スレッドを作成する"
external agent make_thread() -> string from "ai_server:make_thread"
```

### 5.6 設定

```yaml
external_katari_endpoints:
  ai_server: "http://ai:8000/katari"
```

環境変数 (AI server の `.env` または docker-compose の `environment`):

```
RUNTIME_KATARI_ENDPOINT=http://runtime:8000/katari
ANTHROPIC_API_KEY=...
```

---

## 6. Discord Server

### 6.1 役割

Discord Bot に関する agent definition と request を提供するサーバー。

### 6.2 提供する Request

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

### 6.3 提供する Agent Definition

#### watch_channel

```
agent watch_channel(channel_id: string | null, guild_id: string | null) -> null with on_message | on_reaction
```

Discord のイベントを listen する。フィルタ条件を指定可能。`null` の場合は全てのイベントを受信する。

- handler が `continue` すると次のイベントを待つ
- handler が `break` すると listen を停止

#### send_message

```
agent send_message(channel_id: string, content: string) -> string
```

メッセージを送信する。戻り値はメッセージ ID。

#### send_embed

```
agent send_embed(channel_id: string, embed: {
  title: string | null,
  description: string | null,
  color: integer | null,
  fields: array[{name: string, value: string, inline: boolean | null}] | null
}) -> string
```

Embed メッセージを送信する。戻り値はメッセージ ID。

#### add_reaction

```
agent add_reaction(channel_id: string, message_id: string, emoji: string) -> null
```

メッセージにリアクションを追加する。

### 6.4 イベントハンドリングモデル

Discord server は WebSocket 経由で Discord Gateway に接続し、リアルタイムにイベントを受信する。`watch_channel` agent が spawn されると、以下の流れでイベントが処理される:

1. Discord Gateway からイベント (MESSAGE_CREATE, MESSAGE_REACTION_ADD 等) を受信する
2. `watch_channel` のフィルタ条件 (`channel_id`, `guild_id`) に合致するイベントを選別する
3. 合致したイベントを対応する request (`on_message`, `on_reaction`) として親 agent に発行する
4. 親 agent の handler が `continue` を返すと、次のイベント待機に戻る
5. 親 agent の handler が `break` を返すと、`watch_channel` agent は return して終了する

### 6.5 KATARI 側の宣言例

```katari
// lib/discord.ktr
@"メッセージ受信イベント"
external request on_message(message: {
  channel_id: string @ "チャンネル ID"
  author_id: string @ "送信者 ID"
  content: string @ "メッセージ内容"
  guild_id: string @ "サーバー ID"
}) -> null from "discord_server:on_message"

@"リアクション追加イベント"
external request on_reaction(reaction: {
  message_id: string @ "メッセージ ID"
  channel_id: string @ "チャンネル ID"
  user_id: string @ "ユーザー ID"
  emoji: string @ "絵文字"
}) -> null from "discord_server:on_reaction"

@"Discord イベントを listen する"
external agent watch_channel(channel_id: string | null, guild_id: string | null) -> null with on_message | on_reaction from "discord_server:watch_channel"

@"メッセージを送信する"
external agent send_message(channel_id: string, content: string) -> string from "discord_server:send_message"

@"Embed メッセージを送信する"
external agent send_embed(channel_id: string, embed: {
  title: string | null @ "タイトル"
  description: string | null @ "説明"
  color: integer | null @ "色"
  fields: array[{name: string, value: string, inline: boolean | null}] | null @ "フィールド"
}) -> string from "discord_server:send_embed"

@"リアクションを追加する"
external agent add_reaction(channel_id: string, message_id: string, emoji: string) -> null from "discord_server:add_reaction"
```

### 6.6 設定

```yaml
external_katari_endpoints:
  discord_server: "http://discord:8000/katari"
```

環境変数:

```
DISCORD_BOT_TOKEN=...
```

---

## 7. Sandbox Server

### 7.1 役割

セキュアな環境でのコマンド実行を提供するサーバー。隔離された Docker コンテナ内でコマンドを実行する。AI agent がコード実行やファイル操作を行う際の安全な実行基盤となる。

### 7.2 提供する Agent Definition

#### create_sandbox

```
agent create_sandbox() -> string
```

サンドボックス (Docker コンテナ) を作成する。戻り値はサンドボックス ID。

#### destroy_sandbox

```
agent destroy_sandbox(sandbox_id: string) -> null
```

サンドボックスを破棄する。

#### exec

```
agent exec(sandbox_id: string, command: string, timeout_ms: integer | null) -> {
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
agent exec_with_stdin(sandbox_id: string, command: string, stdin: string, timeout_ms: integer | null) -> {
  stdout: string,
  stderr: string,
  exit_code: integer
}
```

stdin 付きでコマンドを実行する。

#### write_file

```
agent write_file(sandbox_id: string, path: string, content: string) -> null
```

サンドボックス内にファイルを書き込む。

#### read_file

```
agent read_file(sandbox_id: string, path: string) -> string
```

サンドボックス内のファイルを読む。

### 7.3 KATARI 側の宣言例

```katari
// lib/sandbox.ktr
@"サンドボックスを作成する"
external agent create_sandbox() -> string from "sandbox_server:create_sandbox"

@"サンドボックスを破棄する"
external agent destroy_sandbox(sandbox_id: string) -> null from "sandbox_server:destroy_sandbox"

@"コマンドを実行する"
external agent exec(sandbox_id: string, command: string, timeout_ms: integer | null) -> {
  stdout: string @ "標準出力"
  stderr: string @ "標準エラー出力"
  exit_code: integer @ "終了コード"
} from "sandbox_server:exec"

@"stdin 付きでコマンドを実行する"
external agent exec_with_stdin(sandbox_id: string, command: string, stdin: string, timeout_ms: integer | null) -> {
  stdout: string @ "標準出力"
  stderr: string @ "標準エラー出力"
  exit_code: integer @ "終了コード"
} from "sandbox_server:exec_with_stdin"

@"ファイルを書き込む"
external agent write_file(sandbox_id: string, path: string, content: string) -> null from "sandbox_server:write_file"

@"ファイルを読む"
external agent read_file(sandbox_id: string, path: string) -> string from "sandbox_server:read_file"
```

### 7.4 設定

```yaml
external_katari_endpoints:
  sandbox_server: "http://sandbox:8000/katari"
```

---

## 8. Primitive Operations (組み込み agent / request)

以下の組み込み agent / request は IR に含まれず、ランタイムが直接実装する。`ICall` や `IRequest` で対応する AgentId / RequestId が参照された場合、ランタイムはネイティブ実装を呼び出す。詳細は [05-runtime.md](05-runtime.md) の第 11 章も参照。

### 8.1 組み込み Agent Definition

| 修飾名               | 引数                                                  | 戻り値    | 説明                                                                  |
| -------------------- | ----------------------------------------------------- | --------- | --------------------------------------------------------------------- |
| `prim.to_string`     | `(v: integer \| number \| boolean \| string \| null)` | `string`  | 値を文字列に変換する                                                  |
| `prim.div`           | `(a: integer \| number, b: integer \| number)`        | `integer` | 床除算 (floor division)                                               |
| `prim.mod`           | `(a: integer \| number, b: integer \| number)`        | `number`  | 剰余                                                                  |
| `prim.parse_integer` | `(s: string)`                                         | `integer` | 文字列を integer にパース。失敗時は `prim.parse_error` request を発行 |
| `prim.parse_number`  | `(s: string)`                                         | `number`  | 文字列を number にパース。失敗時は `prim.parse_error` request を発行  |
| `prim.parse_boolean` | `(s: string)`                                         | `boolean` | 文字列を boolean にパース。失敗時は `prim.parse_error` request を発行 |
| `prim.length`        | `(arr: array)`                                        | `integer` | 配列長を返す                                                          |
| `prim.slice`         | `(arr: array, start: integer, end: integer)`          | `array`   | 配列スライス                                                          |

### 8.2 ログ agent (prim.log モジュール)

| 修飾名           | 引数            | 戻り値 | 説明           |
| ---------------- | --------------- | ------ | -------------- |
| `prim.log.info`  | `(msg: string)` | `null` | 情報ログ出力   |
| `prim.log.warn`  | `(msg: string)` | `null` | 警告ログ出力   |
| `prim.log.error` | `(msg: string)` | `null` | エラーログ出力 |

ログ agent は request を発生させない。ランタイムが直接処理する。

### 8.3 組み込み Request

| 修飾名             | 引数                | 戻り値  | 説明                                                        |
| ------------------ | ------------------- | ------- | ----------------------------------------------------------- |
| `prim.throw`       | `(message: string)` | `never` | エラー request。全 agent に暗黙的に `with throw` が含まれる |
| `prim.parse_error` | `(message: string)` | `never` | パース失敗 request                                          |

#### prim.throw の特殊性

- **暗黙的な包含**: 全ての agent は暗黙的に `with throw` を含む。`with` 節に明示しなくても `throw` は常に perform 可能。
- **effect 型への影響なし**: `handle` ブロック内に `throw` case を書いた場合も、effect 型には一切影響を与えない。
- **デフォルトハンドラ**: ランタイムはトップレベル agent (root) に暗黙的な `throw` handler を提供する。未処理の `throw` はランタイムがエラーメッセージとスタックトレースと共に agent を終了させる。

---

## 9. Docker Compose 構成例

### 9.1 docker-compose.yaml

```yaml
version: "3"
services:
  runtime:
    image: katari-runtime:latest
    ports:
      - "8000:8000"
    volumes:
      - ./katari_config.yaml:/app/katari_config.yaml
    environment:
      - KATARI_CONFIG=/app/katari_config.yaml

  cron:
    image: katari-cron:latest
    ports:
      - "8001:8000"
    environment:
      - RUNTIME_KATARI_ENDPOINT=http://runtime:8000/katari
    depends_on:
      - runtime

  ai:
    image: katari-ai:latest
    ports:
      - "8002:8000"
    environment:
      - RUNTIME_KATARI_ENDPOINT=http://runtime:8000/katari
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
    depends_on:
      - runtime

  discord:
    image: katari-discord:latest
    ports:
      - "8003:8000"
    environment:
      - RUNTIME_KATARI_ENDPOINT=http://runtime:8000/katari
      - DISCORD_BOT_TOKEN=${DISCORD_BOT_TOKEN}
    depends_on:
      - runtime

  sandbox:
    image: katari-sandbox:latest
    ports:
      - "8004:8000"
    environment:
      - RUNTIME_KATARI_ENDPOINT=http://runtime:8000/katari
    privileged: true # Docker-in-Docker for isolation
    depends_on:
      - runtime
```

### 9.2 サービス依存関係

```
runtime  <---  cron
         <---  ai
         <---  discord
         <---  sandbox
```

全ての外部サーバーは runtime に依存する。runtime が起動し、IR がデプロイされた後に外部サーバーが agent definition を参照可能になる。

### 9.3 環境変数

| 変数名                    | 対象サーバー   | 説明                       |
| ------------------------- | -------------- | -------------------------- |
| `RUNTIME_KATARI_ENDPOINT` | 全外部サーバー | runtime の katari base URL |
| `ANTHROPIC_API_KEY`       | AI server      | Anthropic API キー         |
| `DISCORD_BOT_TOKEN`       | Discord server | Discord Bot トークン       |
| `KATARI_CONFIG`           | runtime        | 設定ファイルのパス         |

### 9.4 ネットワーク

docker-compose のデフォルトネットワーク上で全サーバーが通信する。各サーバーはサービス名 (例: `runtime`, `cron`, `ai`) でホスト名解決が可能。外部公開が必要なサーバーのみ `ports` でホストにバインドする。

---

## 10. サーバーの仮想モジュール

runtime 以外のサーバーは明示的なモジュールシステムを持たないが、`GET /agent_def` と `GET /request` の `name` フィールドでモジュール風の名前空間を使用可能:

- `cron_server:schedule` -> name: `schedule`
- `cron_server:cron.schedule` -> name: `cron.schedule` (仮想モジュール `cron`)

これにより、KATARI のモジュールシステムとの親和性を保つ。
