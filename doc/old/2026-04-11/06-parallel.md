# KATARI Language Specification - Par 式 / 並行実行

## 概要

`par` は KATARI の並行実行の基本構成要素である。旧 `fork`/`join` を置き換える。`par` は複数のブロックを並行実行し、全ブロックの結果を配列として返す。

## 構文

### par

```katari
let results = par [
  { ask_claude(question) },
  { ask_gpt(question) }
]
// results: array[string] (両ブロックが string を返す場合)
```

- `par` はブロックのリストを受け取る式。各ブロックは `{ stmt* expr }` 形式。
- 各ブロックは独立したエージェントとして起動される。
- 全ブロックが完了すると `par` は `array[T1 | T2 | ...]` を返す (各ブロックの返り値の union 型の配列)。
- ブロックは周囲の `let` 変数を参照できる (capture by value)。直接変数の変更はできない。
- `par []` は `array[never]` を返す (空の並行実行)。

## 通常のタスク呼び出しとの関係

通常のタスク呼び出しは**同期呼び出し**であり、呼び出し元エージェントが子エージェントの完了を待機する。これも suspension point である (子エージェントからの effect を処理できる)。

```katari
let x = add(1, 2)
// x は add(1, 2) の結果。add 完了まで呼び出し元は待機。
```

`par` を使うと複数のタスクを並行して実行できる:

```katari
let results = par [
  { add(1, 2) },
  { add(3, 4) }
]
// results: array[integer] = [3, 7]
```

**例外**: プリミティブ演算 (算術演算、比較等) は IR 命令であり、エージェント生成は行わない。

## handle ブロックとの連携

handle ブロックは以前と同様にタスク本体内にインラインで記述する。par ブロックから発行される effect は、par を実行しているエージェント (親) に送られる。

```katari
request log(message: string) -> null

task parent() -> null {
  handle {
    request log(msg) => {
      prim.log.info(msg)
      reply null
    }
  }
  par [
    { child_a() },
    { child_b() }
  ]
}

task child_a() -> null with log {
  log("hello from child_a")
}

task child_b() -> null with log {
  log("hello from child_b")
}
```

## Effect ルーティング (親ベースルーティング)

KATARI の effect ルーティングは**常に直接の親エージェントへ**送られる。

### 基本ルール

- 子エージェントが effect を発行すると、まず直接の親エージェントに送られる。
- 親が対応する handle ブロックを持っていれば、そこで処理される。
- 持っていなければ、親は**その親 (祖父母エージェント)** に転送する。
- これをルートエージェントまで繰り返す。

```
child → parent → grandparent → ... → root
```

### 転送中の非再入性

エージェントが effect を上位に転送している間は、そのエージェントは「処理中」とみなされる (非再入)。この間、他の effect リクエストはキューで待機する。

## 並行エージェントの Effect キューイング

par ブロックの複数のエージェントが同一の親に effect を送る場合:

1. effect はキューに入れられ、到着順 (FIFO) に逐次処理される。
2. handle パラメータはキュー順で共有・更新される。
3. ある effect の処理中 (suspension 中を含む) に他の effect が到着した場合、キューで待機し、逐次処理される。

```katari
request log(message: string) -> null

task concurrent_logging() -> null {
  handle(count: integer = 0) {
    request log(msg) => {
      // 両ブロックからの log request は到着順に逐次処理される
      // count は共有され、順番に更新される
      prim.log.info(f"[${prim.to_string(count)}] ${msg}")
      reply null with { count = count + 1 }
    }
  }
  par [
    { worker("task A") },
    { worker("task B") }
  ]
}

task worker(name: string) -> null with log {
  log(name ++ " started")
  log(name ++ " finished")
}
```

## 協調イベントループ統合

### サスペンションポイント

以下の操作は**サスペンションポイント**である:

1. **通常のタスク呼び出し** (`task_call()`) — 子エージェントの完了待機
2. **`par` 式** — 全 par ブロックエージェントの完了待機
3. **`for wait`** — イベントストリームの待機

サスペンションポイントに到達すると、エージェントは自身の request queue を確認し、保留中の effect を処理する。

### 非再入性

エージェントは**完全に非再入 (non-reentrant)** である。同時に実行されるハンドラは常に最大 1 つ:

- request は FIFO キューに蓄積され、1 件ずつ逐次処理される。これは request の種類に関係なく適用される。
- サスペンションポイントに到達すると、エージェントは協調的にキューを確認し、pending な request を 1 件処理する。これは**並行実行ではなく逐次処理**である。
- **並行実行は par ブロックによってのみ実現される**: par ブロック内の各ブロックは独立した子エージェントとして実行されるため、それぞれが独立して request を処理できる。

**転送中は全 request が待機**: agent が `IRequest` を上位に転送している間 (WaitingReply 状態) は、cooperative event loop のキューチェックも行わない。

```
単一エージェント = 完全直列 (1 度に 1 request)
par ブロック    = 別エージェント → 並行処理が可能
```

## par と break の相互作用

いずれかの par ブロックが handle ブロックの handler を通じて break を引き起こした場合:

1. 全ての par ブロックエージェントに `terminate` が送信される。
2. par 式の結果は使用されない (ブロックは破棄)。
3. `break` の値がタスクの返り値となる。

```katari
request first_result(value: string) -> never

task ask_fastest(question: string) -> string {
  handle {
    request first_result(value) => {
      break value
    }
  }
  par [
    { first_result(ask_claude(question)) },
    { first_result(ask_gpt(question)) }
  ]
}
```

`first_result` は `-> never` なので handler は必ず `break` する。最初に到着した結果で break が発行され、もう一方のエージェントは terminate される。

## 本体の正常完了

タスクの本体が `return` または末尾到達で正常完了する時点では、生存中の子エージェントは存在しない。`par` も通常のタスク呼び出しも**同期サスペンションポイント**であり、子エージェントの完了を待機してから次の命令に進むためである。したがって正常完了時に terminate を送信する必要はない。

## Terminate 伝播 (break による中断)

子エージェントが残るのは `handle` ブロックの handler が `break` を発行した時のみである。break は `par` または通常のタスク呼び出しで待機中の body を強制中断するため、待機対象だった子エージェントが宙に浮く。この場合の terminate 伝播の手順:

1. 該当する handler スコープ内で生成された全ての**直接の**子エージェントに terminate が送信される。
2. terminate は再帰的に伝播する (子エージェントはその子エージェントに terminate を伝播する)。
3. 各子エージェントは terminate を acknowledge してから終了する。
4. 親は全ての terminate_ack を受け取った後に `break` 値で handle スコープを完了する。

## 重要: par ブロックの共通祖先による Effect の直列化

**これは par 導入による意図的な挙動変化である。**

```katari
task task1() -> null {
  handle {
    request eff1() => { ... }
  }
  task2()
}

task task2() -> null {
  handle {
    request eff2() => { ... }
  }
  par [
    { eff1() },   // block_a
    { eff2() }    // block_b
  ]
}
```

この例では:

- block_a が `eff1()` を発行 → task2 に送られる → task2 は `eff1` を持たないので task1 に転送
- **task2 は task1 に転送中 (非再入状態)**
- block_b が `eff2()` を発行 → task2 に送られる → **task2 は転送中なのでキューで待機**
- したがって `eff1` と `eff2` は**同時に実行されない**

これは task2 が両 effect の共通祖先であり、非再入であるためである。この挙動は設計上意図されており、親エージェントへの直列化アクセスを保証する。

## エラー処理

`throw` は全てのタスクに暗黙的に含まれる。par ブロックで throw が未処理の場合:

1. ブロックエージェントはエラー状態になる。
2. throw は親エージェントに伝播する。
3. 親の handle ブロックで処理されれば対応、なければ上位に伝播。

この伝播はエージェントツリーのルートまで継続する。ルートでも処理されなかった場合、プログラムはエラー終了する。

## 例

### 基本的な並列実行

```katari
task ask_multiple(question: string) -> array[string] {
  par [
    { ask_claude(question) },
    { ask_gpt(question) }
  ]
}
```

結果の順序は par 内のブロックの順序に対応する。上の例では両ブロックが並列に実行され、全完了後に結果の配列が返る。

### Cron スケジュール

```katari
task daily_time_log() -> null {
  handle(count: integer = 0) {
    request cron.notify(time) => {
      prim.log.info(time)
      if count >= 30 {
        break null
      }
      reply null with { count = count + 1 }
    }
  }
  cron.schedule("0 0 * * *")
}
```

`cron.schedule` は外部サーバーが提供するタスクであり、毎日 0 時に `cron.notify` effect を発行する。handler は 30 回通知を受け取った後に `break` してタスクを終了する。

### 複数ワーカーの集約

```katari
request report(value: integer) -> null

task aggregate_workers() -> integer {
  handle(total: integer = 0) {
    request report(value) => {
      reply null with { total = total + value }
    }
    return _ => {
      total
    }
  }
  par [
    { compute_worker(data_1) },
    { compute_worker(data_2) },
    { compute_worker(data_3) }
  ]
}

task compute_worker(data: array[integer]) -> null with report {
  let result = heavy_computation(data)
  report(result)
}
```

各ワーカーが `report` effect で結果を報告し、handle パラメータ `total` に集約される。全ワーカー完了後、`return` 節で集約結果を返す。

### タイムアウトパターン

```katari
request timeout() -> never

task with_timeout() -> string {
  handle {
    request timeout() => {
      break "timed out"
    }
  }
  par [
    { long_running_task() },
    { timer(5000) }
  ]
}

task timer(ms: integer) -> null with timeout {
  cron.delay(ms)
  timeout()
}
```

`timer` タスクが指定ミリ秒後に `timeout` effect を発行する。handler は `break "timed out"` で par ブロックを全て terminate し、タスクは `"timed out"` を返す。
