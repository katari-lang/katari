# KATARI Language Specification - Katari Protocol

## 概要

Katari Protocol は、KATARI の分散実行基盤を構成するサーバー間通信プロトコルである。REST API ベースで、各サーバーは共通のエンドポイント群を katari base URL 以下に提供する。全てのプロトコルエンドポイントは katari base URL (例: `http://localhost:8000/katari`) を起点とする。

## 基本概念

### サーバー

各サーバーは Katari Protocol を実装し、`katari_config.yaml` で定義された katari base URL でエンドポイントを公開する。サーバーの種類については [10-servers.md](10-servers.md) を参照。

### Task

agent の設計図。KATARI の `task` 定義に対応する。サーバーが提供する呼び出し可能な機能を定義する。

### Agent

task の実行インスタンス。固有の `agent_id` を持つ。agent は木構造 (親子関係) を形成する。ユーザーもネットワーク上の agent として扱われる。

### Effect (Request)

子 agent が直接の親 agent に対して処理を要請する行為。KATARI の `request` に対応する。固有の `request_id` を持つ (冪等性のための識別子)。各 request は `request_name` で種別を特定する。request は常に直接の親エージェントに送られ、処理できない場合はさらに上位に転送される。

### Handle Block

agent が提供する request の処理能力。KATARI の `handle` block に対応する。agent はアクティブな handle block を持ち、子エージェントから届いた request をハンドラで処理するか、対応する handler がない場合は自身の親に転送する (プロキシモード)。

## プロトコル操作

Katari Protocol は正確に 6 つの操作で構成される。

### 親 agent が実行する操作

| 操作                                             | 説明                           |
| ------------------------------------------------ | ------------------------------ |
| `spawn(task_id, args, with_effects)` → agent_id | 子 agent を生成する            |
| `reply(request_id, value)`                       | 子 agent の request に応答する |
| `terminate(agent_id)`                            | 子 agent に停止を指示する      |

### 子 agent が実行する操作

| 操作                                            | 説明                                           |
| ----------------------------------------------- | ---------------------------------------------- |
| `request(request_name, args)` → waits for reply | 直接の親 agent に処理を要請する (応答まで待機) |
| `return(value)`                                 | 正常完了し結果を返す                           |
| `terminate_ack()`                               | 停止指示を受理したことを通知する               |

## エンドポイント

全エンドポイントは katari base URL (例: `http://localhost:8000/katari`) 以下に配置される。以下に示すパスは全て katari base URL からの相対パスである。

---

### GET /request

提供する request 定義を返す。

**Request Parameters:**

```json
{
  "module_name": "string (optional)"
}
```

- `module_name`: モジュール名で絞り込む。exact match のみ (部分指定不可)。省略時は全 request を返す。

**Response:**

```json
[
  {
    "request_id": "string",
    "request_where": "URL",
    "name": "string",
    "description": "string",
    "arg_types": ["JSON Schema"],
    "return_type": "JSON Schema"
  }
]
```

- `request_id`: request の一意な識別子。
- `request_where`: request 定義が位置する URL。
- `name`: request の名前。モジュールがネストする場合は `path.to.request_name` 形式。
- `description`: semantic annotation から生成された説明。
- `arg_types`: 引数の型の JSON Schema の配列。
- `return_type`: 返り値の型の JSON Schema。

**runtime サーバーの場合**: `external` 以外の全 request を返す。

---

### GET /task

提供する task 定義を返す。

**Request Parameters:**

```json
{
  "module_name": "string (optional)"
}
```

**Response:**

```json
[
  {
    "task_id": "string",
    "task_where": "URL",
    "name": "string",
    "description": "string",
    "arg_types": ["JSON Schema"],
    "return_type": "JSON Schema"
  }
]
```

- `task_id`: task の一意な識別子。
- `task_where`: task が位置する URL。POST /agent する際の宛先。

**runtime サーバーの場合**: `external` 以外の全 task を返す。

---

### GET /agent/:agent_id

agent の詳細情報を返す。

**Response:**

```json
{
  "agent_id": "string",
  "agent_where": "URL",
  "task_id": "string",
  "args": ["any"],
  "parent_agent_id": "string",
  "parent_agent_where": "URL",
  "with_effects": ["string"],
  "child_agents": [
    {
      "agent_id": "string",
      "agent_where": "URL"
    }
  ]
}
```

- `parent_agent_id`: 直接の親 agent の識別子。
- `parent_agent_where`: 直接の親 agent が位置する URL。request 発行時の送信先。
- `with_effects`: この agent が発行できる request 名のリスト (spawn 時に指定)。

---

### GET /agent

全 agent の一覧を返す。

**Response:**

```json
[
  {
    "agent_id": "string",
    "agent_where": "URL",
    "task_id": "string",
    "args": ["any"]
  }
]
```

---

### POST /agent

新しい agent を生成・開始する。親→子。

**Request:**

```json
{
  "task_id": "string",
  "args": ["any"],
  "parent_agent_id": "string",
  "parent_agent_where": "URL",
  "with_effects": ["string"]
}
```

- `parent_agent_id`: 親 agent の識別子。
- `parent_agent_where`: 結果を返すべき場所 (親 agent が位置する URL)。子 agent が request を発行する際の送信先にもなる。
- `with_effects`: この agent が発行できる request 名のリスト。型検証に使用。

**Response:**

```json
{
  "agent_id": "string",
  "agent_where": "URL"
}
```

呼ばれた側は agent_id を生成して即座に返す。agent の実行を開始する。

---

### POST /agent/request

子 agent が直接の親 agent に request の処理を要請する。子→親。このエンドポイントは `parent_agent_where` の URL に対して呼び出される。

**Request:**

```json
{
  "request_id": "string",
  "request_name": "string",
  "args": ["any"],
  "from_agent_id": "string",
  "from_agent_where": "URL"
}
```

- `request_id`: この request の冪等性キー。reply 時にどの request に対する応答かを特定するために使用。リトライ時に同じ値を送ることで重複処理を防ぐ。
- `request_name`: 呼び出す request の名前。
- `from_agent_id`: request を発行した agent の識別子。
- `from_agent_where`: 結果を返すべき場所 (reply の宛先)。

**Response:**

```json
{
  "success": true
}
```

親 agent は対応する handle block でこの request を処理するか、自身の親に転送する (Effect ルーティング参照)。

---

### POST /agent/reply

親 agent が子 agent の request に応答する。親→子。

**Request:**

```json
{
  "request_id": "string",
  "result": "any",
  "from_agent_id": "string",
  "from_agent_where": "URL",
  "agent_id": "string"
}
```

- `request_id`: 対応する request の冪等性キー。
- `result`: handler が返す値。
- `from_agent_id`: 最終的に処理した handler agent の識別子。
- `from_agent_where`: handler agent が位置する URL。
- `agent_id`: request を発行した子 agent の識別子。

**Response:**

```json
{
  "success": true
}
```

---

### POST /agent/terminate

親 agent が子 agent に停止を指示する。親→子。

**Request:**

```json
{
  "agent_id": "string",
  "from_agent_id": "string",
  "from_agent_where": "URL"
}
```

- `agent_id`: 停止対象の子 agent の識別子。
- `from_agent_id`: 停止を指示する親 agent の識別子。
- `from_agent_where`: terminate_ack を返すべき場所。

**Response:**

```json
{
  "success": true
}
```

---

### POST /agent/return

子 agent が正常完了し、結果を親に返す。子→親。

**Request:**

```json
{
  "result": "any",
  "from_agent_id": "string",
  "from_agent_where": "URL",
  "agent_id": "string"
}
```

- `result`: 子 agent の戻り値。
- `from_agent_id`: 子 agent の識別子。
- `agent_id`: 親 agent の識別子。

**Response:**

```json
{
  "success": true
}
```

---

### POST /agent/terminate_ack

子 agent が停止指示の受理を親に通知する。子→親。

**Request:**

```json
{
  "from_agent_id": "string",
  "from_agent_where": "URL",
  "agent_id": "string"
}
```

- `from_agent_id`: 停止した子 agent の識別子。
- `from_agent_where`: 子 agent が位置する URL。
- `agent_id`: 親 agent の識別子。

**Response:**

```json
{
  "success": true
}
```

---

**注意**: `/error` エンドポイントは存在しない。エラーは `throw` request によって処理される。

## Effect ルーティング

### 基本ルール

子 agent が request を発行すると、常に**直接の親 agent** (`parent_agent_where`) に送られる。

```
child → parent → grandparent → ... → root
```

1. 親が対応する handle block を持っていれば、そこで処理され、reply が返される。
2. 持っていなければ、親は**自身の親** (`parent_agent_where`) に転送する (プロキシモード)。
3. これをルートエージェントまで繰り返す。ルートでも処理されなかった場合、エラーとなる。

### 転送中の非再入性

エージェントが request を上位に転送している間は「転送中」とみなされ、非再入状態になる。この間、他の request はキューで待機する。par ブロックの複数の子エージェントが同一の親に request を送る場合でも、この直列化が保証される。

## ルール

1. **必ず終了する**: agent は必ず最終的に終了する (return または terminate_ack)。
2. **子の先行終了**: agent が終了する時点で、全ての子 agent が既に終了している必要がある。
3. **throw は組み込み request**: `throw` は組み込みの request であり、ランタイムが暗黙のトップレベル handler を提供する。
4. **未処理の throw**: 未処理の `throw` はランタイムが agent をエラー結果で終了させる。
5. **冪等性**: `request_id` により request はリトライセーフである。
6. **request は木を上る**: request は子から祖先方向にのみ発行される。
7. **terminate は木を下る**: terminate は親から子方向に再帰的に伝播する。
8. **親ベースルーティング**: request は常に直接の親エージェントに送られ、handler がなければ順に上位に転送される。
9. **転送中は非再入**: エージェントが request を転送している間は非再入状態となり、他の request は待機する。

## 実行フロー

### 基本フロー

```
1. 各サーバーは POST /agent を待機
2. 受信時: agent を作成し agent_id を返す → 実行開始
3. 子 task を呼びたい場合:
   a. 子サーバーの POST /agent に POST (spawn)
      parent_agent_id と parent_agent_where を指定
      with_effects で許可する request 名のリストを提供
   b. 以下を待機:
      - POST /agent/return → 子の完了。結果を受け取り実行再開
      - POST /agent/request → request の処理要請
      - POST /agent/terminate → 親からの停止指示
4. request を行いたい場合:
   a. spawn 時に受け取った parent_agent_where に POST /agent/request を送る
   b. 以下を待機:
      - POST /agent/reply → 値を受け取り実行再開
      - POST /agent/terminate → 停止指示
5. 実行完了:
   a. POST /agent/return で結果を親に返す
```

### Effect ルーティングフロー

```
Agent A (handle block で request X を処理)
  → POST /agent → Agent B (parent_agent_where = A's URL, with_effects: ["X"])
    → B が X を request
    → B の parent_agent_where (= A) に POST /agent/request を送る
    → A が handle block の該当 case を実行
    → A → POST /agent/reply (request_id: "r1") → B (from_agent_where)
    → B が実行を再開
```

### Effect 転送フロー

```
Agent Root (handle block で request X を処理)
  → POST /agent → Agent Middle (parent = Root)
    → POST /agent → Agent Child (parent = Middle)
      → Child が X を request
      → Child → POST /agent/request (X) → Middle (parent)
      → Middle は X の handler を持たない
      → Middle → POST /agent/request (X) → Root (Middle の parent) [転送]
        (Middle は転送中、非再入状態)
      → Root が X を処理
      → Root → POST /agent/reply → Middle (from_agent_where = Child のアドレス)
      → Middle → POST /agent/reply → Child (元の from_agent_where)
      → Child が実行を再開
```

### Terminate フロー

```
1. 親が POST /agent/terminate を子に送信
2. 子は自身の子 agent に terminate を送信
3. 孫 agent が terminate_ack を返す
4. 全ての子 agent が terminate_ack を返した後、
   子が POST /agent/terminate_ack を親に送信
```

### Break (Dismiss) フロー

KATARI の `break` (handle block 内でスコープ全体を中断する操作) は以下のように処理される:

```
1. Handle block が break を決定
2. Runtime がこの agent の全直接子 agent に terminate を送信
3. 全ての terminate_ack を待機
4. Break の値を task の結果として返す
```

### par ブロックでの Effect 処理

```
Agent A (handle block で request X を処理)
  → par で B1, B2 を同時に POST /agent (spawn)
    (B1, B2 の parent_agent_where は A)
  → B1 が X を request → A (request_id: "r1")
  → A が handle block の case を実行中
  → B2 が X を request → A (request_id: "r2")
  → r2 は queue に入れられる
  → A が r1 の処理を完了 → POST /agent/reply (request_id: "r1") → B1
  → A が r2 の処理を開始
  → A が r2 の処理を完了 → POST /agent/reply (request_id: "r2") → B2
```

handle パラメータは r1 → r2 の順で更新される。

## 設定ファイル

### katari_config.yaml

```yaml
runtime:
  port: 8000
  katari_endpoint: "http://localhost:8000/katari"

external_katari_endpoints:
  cron_server: "http://localhost:8001/katari"
```

- `runtime.katari_endpoint`: runtime サーバー自身の katari base URL。全プロトコルエンドポイントはこの URL 以下に配置される。
- `external_katari_endpoints`: 外部サーバー名と katari base URL のマッピング。`external task` / `external request` の `from "server_name:..."` と対応。
