# KATARI Language Specification - Request System

## 1. 概要

KATARI の request system は one-shot algebraic effect に基づく。エージェントモデルとの整合性のため、effect/handler の概念を request/handle として再定義している。

- タスクは発生させる可能性のある request を `with` 節で宣言する。
- タスク本体内の `handle` ブロックで、子エージェントからの request を処理するハンドラを定義する。
- 1 つのタスク内に複数の `handle` ブロックを配置でき、段階的に能力を追加できる。

## 2. Request の定義

```katari
@"エラーをスローする"
request throw(message: string) -> never

@"ログを出力する"
request log(message: string) -> null

@"ユーザーに質問する"
request ask(question: string) -> string
```

### Request の返り値型

- `-> T`: request を perform した式の型が `T` になる。handler が `reply val` で `val: T` を返す。
- `-> never`: `never` 型の値を構成できないため、handler は `reply` を行うことができない。従って `break` のみが可能となる。これは特別なルールではなく、通常の型システム規則から自然に導かれる帰結である。

### 制約

- request 定義それ自体は型宣言であり、副作用を持たない。
- ただし、`handle` ブロック内の request case (ハンドラ本体) では他の request を実行できる。実行された request はより上位のハンドラに送信される。
- request の返り値型 `T` は省略不可能。

## 3. Request の使用 (with 節)

request はタスク本体内で通常の関数呼び出しと同じ構文で使用する:

```katari
task safe_divide(a: number, b: number) -> number with throw {
  if b == 0 {
    throw("division by zero")
  }
  a / b
}

task logging_task() -> null with log {
  log("starting process")
  log("done")
}
```

`with` 節はそのタスクが発生させる可能性のある request を宣言する。

## 4. Handle Block (ハンドラ)

### 基本構文

`handle` ブロックはタスク本体内の**文 (statement)** であり、子エージェントからの request をどう処理するかを定義する。

```katari
task main() -> number {
  handle {
    request throw(e) => {
      break 0
    }
  }
  safe_divide(10, 0)
}
```

`handle` ブロックは `where` 節とは異なり、タスク本体内の任意の位置に記述できるインライン文である。1 つのタスク内に複数の `handle` ブロックを配置できる。

### Handle パラメータ (状態管理)

`handle` ブロックはパラメータを持つことができる。パラメータはハンドラ内の状態変数として機能する。

```katari
handle(count: integer = 0) {
  request notify(time) => {
    prim.log.info(time)
    reply null with { count = count + 1 }
  }
  return result => {
    {count = count}
  }
}
```

構文: `handle(name: type = init_expr, ...) { ... }`

- 各パラメータは名前、型、初期値式で構成される。
- 初期値式は `handle` 文に到達した時点で評価される (詳細は「Handler 初期化タイミング」を参照)。
- パラメータは `request` case 節と `return` 節内でのみアクセス可能。タスクの body からはアクセスできない。
- `reply value with { name = new_expr, ... }` でパラメータを更新する。`with` 節に含まれないパラメータはそのまま引き継がれる。`with` 節なしの `reply` は全てのパラメータを引き継ぐ。
- handler が `reply` ではなく case body の終端まで行って暗黙的に reply した場合、パラメータは全てそのまま引き継がれる。

### Body の `let` バインディングへのクロージャ

`handle` ブロックは、それより前のタスク本体内の `let` バインディング (不変) を参照できる。これは安全である (`let` は不変であるため、並行実行下でも競合が発生しない)。

```katari
task interactive() -> null {
  let thread_id = ai.make_thread()

  handle {
    request ask(question) => {
      reply ai.ask(thread_id, question)
    }
  }

  child_agent()
}
```

上の例では、`handle` ブロック内の `ask` ハンドラが `thread_id` を参照している。`thread_id` は `let` で束縛された不変値であるため、安全にクロージャとして捕捉できる。

### reply / break

#### `reply value`

handler が request の呼び出し元に `value` を返して実行を再開させる。`value` の型は request の返り値型 `T` と一致する必要がある。

```katari
request ask(question: string) -> string

task interactive() -> null {
  handle {
    request ask(question) => {
      reply "default answer"
    }
  }
  let answer = ask("What is your name?")
  prim.log.info(answer)
}
```

#### `reply value with { name = expr, ... }`

reply と同時に handle パラメータを更新する。

```katari
request log(message: string) -> null

task logged_process() -> integer {
  handle(count: integer = 0) {
    request log(message) => {
      prim.log.info(message)
      reply null with { count = count + 1 }
    }
    return result => {
      count
    }
  }
  log("step 1")
  log("step 2")
  42
}
```

#### `break value`

handle ブロックのスコープ全体の実行を中断する。スコープ内の直接の子エージェントに対して terminate が送信される (terminate 伝播については [06-parallel.md](06-parallel.md) を参照)。`value` は handle ブロックのスコープを含む式の戻り値となる。`return` 節は呼ばれない。

なお、**どの子エージェントから request が飛んできたかに関係なく、すべての子エージェントに対して terminate が発火せれる。**

```katari
task main() -> string {
  handle {
    request throw(e) => {
      break "error: " ++ e
    }
  }
  let result = may_fail()
  "success: " ++ result
}
```

### return 節

`return` 節は、handle ブロックのスコープ内の body が正常に完了した際に呼び出される。body の戻り値をパターンで受け取り、変換した値を返す。

```katari
task counted_process() -> {result: string, log_count: integer} {
  handle(count: integer = 0) {
    request log(msg) => {
      prim.log.info(msg)
      reply null with { count = count + 1 }
    }
    return result => {
      {result = result, log_count = count}
    }
  }
  do_something()
}
```

- `return` 節は省略可能。省略した場合、body の戻り値がそのまま返される。
- `return` 節がある場合、handle ブロック全体の型は return 節の body の型になる。
- `break` によりスコープが中断された場合、`return` 節は呼ばれない。

### Handle block のスコープ

`handle` ブロックのスコープは、`handle` 文の位置から、それを囲むブロックの終端までである。

```katari
task example() -> null {
  // ここでは handler なし

  handle {
    request log(msg) => {
      prim.log.info(msg)
      reply null
    }
  }

  // ここから下が handle ブロックのスコープ
  // この範囲で起動された子エージェントが log を使える

  logging_worker()

  // ブロック終端でスコープ終了
}
```

`handle` ブロックのスコープ内で起動された子エージェントが request を発行した場合、その `handle` ブロックのハンドラが処理する。

### Handle のネスト

`handle` ブロックはタスク body 内の任意のブロックに記述できる。スコープは「handle 文からそれを囲むブロックの末端まで」という規則が全ての文脈に共通して適用される。

#### par ブロック内の `handle`

par ブロックは独立した匿名エージェントとして実行される。par ブロック内の `handle` はその匿名エージェントにハンドラを追加する。par ブロック内のタスク呼び出しで生成された子エージェントの request は、まず par ブロックのエージェントに届き、ハンドラがなければ par を起動した親エージェントに転送される (親ベースルーティング)。

```katari
task parent() -> null {
  handle {
    request eff1() => { reply null }  // parent が処理
  }
  par [
    {
      handle {
        request eff2() => { reply null }  // par ブロック A のエージェントが処理
      }
      task2()  // task2 は eff1 (→ parent) も eff2 (→ par ブロック A) も使える
    },
    {
      handle {
        request eff3() => { reply null }  // par ブロック B のエージェントが処理
      }
      task3()  // task3 は eff1 (→ parent) も eff3 (→ par ブロック B) も使える
    }
  ]
}
```

eff2 と eff3 はそれぞれ独立した par ブロックエージェントで処理されるため並行実行できる。eff1 は両ブロックから parent に転送されて処理されるため、parent で直列化される。

#### block 式内の `handle`

`let x = { handle { ... } ... }` のように block 式中に `handle` を記述した場合、スコープはその block の末端まで。block を抜けると handler は無効化される。

```katari
task example() -> integer {
  let x = {
    handle(state: integer = 0) {
      request eff4(v: integer) => {
        reply null with { state = state + v }
      }
      return _ => { state }
    }
    task4()  // task4 は eff4 を使える
  }
  // ここでは eff4 は使えない
  x
}
```

#### handler case body 内の `handle`

handler の case body (block) 内に `handle` ブロックを記述できる。スコープはその case body block の末端まで。case body 内の suspension point (ICall, IPar) で協調的なキューチェックが行われるため、case body 内で定義した `handle` の request を子エージェントが発行した場合、その suspension point で逐次処理される。

```katari
task example() -> null {
  handle {
    request eff1() => {
      handle {
        request eff5(msg: string) => {
          prim.log.info(msg)
          reply null
        }
      }
      // task_with_eff5 が eff5 を使う。eff5 は上の handle で処理される。
      // ICall suspension point で eff5 が逐次処理される (並行ではない)。
      task_with_eff5()
      reply null
    }
  }
  some_task()
}
```

#### return 節内の `handle`

handle ブロックの `return` 節は scope body が正常完了した後に実行される。scope body 完了後にはその body 内の子エージェントは全て終了している。`return` 節の body 内にも `handle` を記述でき、スコープは return 節 body の末端まで。`return` 節の実行中は通常の実行状態 (特定の request を処理中ではない) であるため、suspension point で任意の request queue の処理が可能である。

```katari
handle(count: integer = 0) {
  request log(msg: string) => {
    prim.log.info(msg)
    reply null with { count = count + 1 }
  }
  return result => {
    handle {
      request finalize(v: integer) => { reply v * 2 }
    }
    let final_val = finalize_task(result)  // finalize_task は finalize を使える
    {result = final_val, count = count}
  }
}
```

### Handler の上書き (シャドウイング)

同一の request に対する `handle` ブロックを複数定義した場合、後のブロックが前のブロックをシャドウする。

```katari
task example() -> null {
  handle {
    request log(msg) => {
      prim.log.info("[v1] " ++ msg)
      reply null
    }
  }

  // この時点で起動した子エージェントは v1 のハンドラを使う
  par [
    { worker("first") }
  ]

  handle {
    request log(msg) => {
      prim.log.info("[v2] " ++ msg)
      reply null
    }
  }

  // この時点以降に起動した子エージェントは v2 のハンドラを使う
  par [
    { worker("second") }
  ]
}
```

重要なセマンティクス:

- 新しい `handle` ブロック以降に起動された子エージェントは、新しいハンドラを参照する。
- 新しい `handle` ブロック以前に起動された子エージェントは、引き続き古いハンドラを参照する。

## 5. Cooperative Event Loop

KATARI のエージェントは cooperative event loop モデルで動作する。

### エージェントのライフサイクル

エージェントは以下の状態を遷移する:

```
Running → Suspended → Running → Suspended → ... → 完了
```

- **Running**: タスク本体のコードを実行中。
- **Suspended**: suspension point で一時停止し、request queue の処理やイベント待機を行っている。

### Suspension Point

以下の箇所が suspension point であり、ここで request queue の確認・処理が行われる:

1. **通常のタスク呼び出し** (`task_name(args)`): 子エージェントの完了を待機する。これもサスペンションポイントであるため、子エージェントからの request を処理できる。
2. **`par` 式**: 全 par ブロックエージェントの完了を待機する。
3. **`for` ループのイテレーション待ち**: 次の要素を取得する際に suspension point となる。

### Request Queue

エージェントの request queue は以下のように処理される:

- 子エージェント (およびその子孫) から送信された request は、親エージェントの request queue に FIFO 順で蓄積される。
- エージェントが suspension point に到達した時点で、キューに溜まった request を先頭から順に処理する。
- 各 request は対応するハンドラの case body を実行することで処理される。

### Non-reentrant ハンドラ

エージェントは**完全に非再入 (non-reentrant)** である。同時に実行されるハンドラは常に最大 1 つ:

- request は FIFO キューに蓄積され、1 件ずつ順番に処理される。
- handler case body が suspension point (ICall, IPar) に到達すると、エージェントは協調的にキューを確認し、pending な request を 1 件処理する。これは**並行実行ではなく逐次処理** (cooperative multitasking) である。
- 同一 request の handler case body が既に実行中 (suspension 中を含む) の場合、新たに同一 request が到着してもキューで待機する。これにより handle パラメータの状態が一貫する。
- **並行実行は par ブロックによってのみ実現される**: par ブロック内の各ブロックは独立した子エージェントとして実行されるため、それぞれの handle ブロックが独立して request を処理できる。
- **転送中は全 request が待機**: エージェントが request を上位に転送している間 (プロキシモード、WaitingReply 状態) は、全ての request がキューで待機する (詳細は「親ベースルーティング」を参照)。これは転送先エージェントから reply が返るまで継続する。

```katari
task example() -> null {
  handle(count: integer = 0) {
    request process(data) => {
      // 同一の process request は再入しない (count への安全なアクセスが保証される)
      // heavy_computation 内の suspension point で他の pending request を逐次処理できる
      let result = heavy_computation(data)
      reply result with { count = count + 1 }
    }
  }
  par [
    { worker_1() },
    { worker_2() }
  ]
}
```

### Self-request

エージェントの body が、そのエージェント自身が handle しているタスクを (子エージェント経由ではなく直接) 呼び出す場合の動作:

1. body が request を perform する。
2. body は suspend する。
3. 自身の handler case body が実行される。
4. handler が `reply` すると、body が再開する。

```katari
task self_example() -> null {
  handle(count: integer = 0) {
    request get_count() => {
      reply count with { count = count + 1 }
    }
  }
  // body 自身が get_count を呼ぶことも可能
  // ただし通常は子エージェント経由で使用する
  let c = get_count()
  prim.log.info(prim.to_string(c))
}
```

## 6. 親ベースルーティング

### 基本ルール

子エージェントが request を発行すると、常に**直接の親エージェント**に送られる。

```
child → parent → grandparent → ... → root
```

- 親が対応する `handle` ブロックを持っていれば、そこで処理される。
- 持っていなければ、親は**その親 (祖父母エージェント)** に転送する (プロキシモード)。
- これをルートエージェントまで繰り返す。ルートでも処理されなかった場合、エラーとなる。

### Effect の転送 (プロキシモード)

エージェントが request を上位に転送している間は、そのエージェントは「転送中」とみなされ、非再入状態になる。

- 転送中のエージェントは他の request を処理できない (キューで待機)。
- これにより、par ブロックの複数の子エージェントが同一の親に request を送る場合でも、直列化が保証される。

```katari
task task1() -> null {
  handle {
    request eff1() => {
      reply null
    }
  }
  task2()
}

task task2() -> null {
  handle {
    request eff2() => {
      reply null
    }
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

### Handler 初期化タイミング

handle パラメータの初期値式は、実行が `handle` 文に到達した時点で評価される。

```katari
task example() -> null {
  handle(config: string = load_config()) {
    request get_config() => {
      reply config
    }
  }
  // load_config() は上の handle 文到達時に実行される
  use_config_worker()
}
```

- 初期値式内でタスク呼び出しを行うことは許可される。
- ハンドラは、全てのパラメータの初期化が完了した後に有効になる。
- パラメータ初期化中は、このハンドラは request を処理しない。

## 7. throw (組み込み request)

`throw` は組み込みの request として定義されている:

```katari
request throw(message: string) -> never
```

### 暗黙的な包含

全てのタスクは暗黙的に `with throw` を含む。明示的に `with throw` と書く必要はない。

```katari
// 以下の2つは等価:
task foo() -> number with throw { ... }
task foo() -> number { ... }
```

これは、`throw` がどのタスクからでも発生し得る基本的なエラーメカニズムであるためである。

### ランタイムのデフォルトハンドラ

ランタイムはトップレベルに暗黙的な `throw` ハンドラを提供する:

- ユーザーコードで `throw` が処理されなかった場合、ランタイムのデフォルトハンドラがエラーメッセージと共にエージェントを終了させる。
- ユーザーが `handle` ブロックで `throw` のハンドラを定義した場合、そのスコープ内ではランタイムのデフォルトハンドラがシャドウされる。

```katari
task main() -> string {
  handle {
    request throw(e) => {
      // ランタイムのデフォルトハンドラを上書き
      break "caught: " ++ e
    }
  }
  risky_operation()
}
```

### スタックトレース

ランタイムはエージェントの呼び出し階層を自動的に追跡し、throw 発生時にスタックトレースとして提示する。明示的なスタックトレース操作は不要である。

## 8. Body 完了時の子エージェント終了

タスクの body が正常に完了した場合 (return / ブロック終端に到達)、生存中の子エージェントが存在する場合は以下の手順で終了処理が行われる:

1. 全ての生存中の子エージェントに `terminate` が送信される。
2. 各子エージェントは再帰的に自身の子エージェントに `terminate` を伝播する。
3. 全ての `terminate_ack` を受信した後、エージェントが完了する。

これにより、親エージェントが完了した後に子エージェントが孤立して実行を続けることが防止される。

## 9. for ループ

for ループは handle ブロックと同様のパラメータ更新メカニズムを持つが、制御キーワードは `next` / `break` を使用する。

### 基本構文

```katari
for (let elem of array_expr, var acc: integer = 0) {
  next with {
    acc = acc + elem
  }
} finally {
  acc
}
```

### for ループの各部分

- **`let` バインディング**: イテレーションする配列と要素変数。複数指定でネストループ。
- **`var` バインディング**: ループ変数。各イテレーションで `next with` により更新。
- **body**: 各イテレーションで実行される。最後の式に `next` / `break` がない場合、暗黙的に `next` となる。
- **`finally`**: ループ完了後に実行される。ループ変数にアクセス可能。省略時は `null` を返す。

### for の制御構文

**`next`**: 次のイテレーションへ。ループ変数はそのまま。

**`next with { var = expr, ... }`**: ループ変数を更新して次のイテレーションへ。

**`break value`**: ループを中断。`value` が for 式全体の戻り値となる (`finally` は実行されない)。

### 例: 配列の合計

```katari
task sum(xs: array[integer]) -> integer {
  for (let x of xs, var acc: integer = 0) {
    next with { acc = acc + x }
  } finally {
    acc
  }
}
```

### 例: 条件付き検索

```katari
task find_first_positive(xs: array[integer]) -> integer | null {
  for (let x of xs) {
    if x > 0 {
      break x
    }
  } finally {
    null
  }
}
```

### ネストループ

```katari
for (let x of xs, let y of ys, var sum = 0) {
  next with {
    sum = sum + x * y
  }
} finally {
  sum
}
```

複数の `let` バインディングがある場合、ネストされたループとして展開される。内側から順に回る (上の例では `y` が先に全要素を回る)。

### 空配列の場合

配列が空の場合、body は一度も実行されず、直接 `finally` ブロックが実行される。ループ変数は初期値のまま。

## 10. ネストした for/handle の曖昧性解消

`reply` / `break` と `next` / `break` はそれぞれ異なるコンテキストに属する。キーワードが異なるため、曖昧性は発生しない。

### 解消ルール

- **handle の request case 内の `reply`**: 常に handler の reply を指す。
- **handle の request case 内の `break`**: 常に handler の break を指す (handle ブロックのスコープを中断)。
- **for body 内の `next`**: 常に for ループの次のイテレーションを指す。
- **for body 内の `break`**: 常に for ループの中断を指す。

```katari
task example() -> null {
  handle {
    request some_request() => {
      // ここの reply / break は handler 用
      for (let x of xs) {
        // ここの next / break は for 用
        next
      }
      // ここの reply / break は handler 用
      reply null
    }
  }
  some_task_with_loop()
}
```

- handle の request case 内で for を書いた場合、`next` は for の制御、`reply` は handler の制御を指す。
- for body 内から外側の handler を `reply` / `break` する方法はない (request case 内でないと handler の `reply` / `break` は書けないため)。
- handle の request case 内の for body で `break` を書いた場合、それは for の `break` である。handler を break したい場合は for の外に出る必要がある。

## 11. Request 型チェック

### Request の収集

タスク本体から発生する request は以下のように収集される:

1. 各式について、発生する可能性のある request を集める。
2. block の statement を最後から見ていき、union を取る。
3. `handle` ブロックがある場合:
   - handle で処理対象となる request をスコープ内の request 集合から引く
   - handle の request case 内で発生する request を足す

### Request annotation との照合

```katari
task foo() -> integer with throw | log {
  // body の request が throw | log の部分型であれば OK
}
```

- `with R` が明示されている場合: body の request 集合 (throw を除く) が R の部分集合であることをチェック。throw は暗黙的に含まれるため、明示する必要はない。
- `with R` が省略されている場合: body の request 集合が推論される (throw は暗黙)。
- `with task` と書いた場合: request は空 (task は基底であり request ではない)。body 内で throw 以外の request が発生するとエラー。

### `task` について

`task` は全てのタスクの暗黙的な基底である。全てのタスクは非同期に実行可能。

- `task` は request union には現れない。`with log` は「log request が発生する可能性がある (かつ暗黙的に task、暗黙的に throw)」の意味。
- `with task` は「throw 以外の request なし」を意味する。
- request annotation 完全省略は「request 推論」を意味する。

## 12. External Request

外部サーバーが提供する request:

```katari
@"通知"
external request notify(time: string) -> null from "cron_server:notify"
```

型システム上は通常の request と同様に扱われる。違いはランタイム:

- ランタイム実行前に `cron_server` に問い合わせ、`notify` の `request_id` と URL を取得。
- request 呼び出し時は、直接の親エージェントに送られ、ルーティングに従い処理される。

## 例

### 基本的なエラーハンドリング

```katari
task main() -> number {
  handle {
    request throw(e) => {
      break 0
    }
  }
  safe_divide(10, 0)
}
```

`safe_divide` が `throw` request を発行すると、`main` の `handle` ブロックが捕捉し、`break 0` により `main` の結果を `0` として返す。

### 状態を持つハンドラ

```katari
task daily_logger() -> {count: integer} {
  handle(count: integer = 0) {
    request notify(time) => {
      prim.log.info(time)
      reply null with { count = count + 1 }
    }
    return result => {
      {count = count}
    }
  }
  cron.schedule("0 0 * * *")
}
```

### クロージャを利用したハンドラ

```katari
task interactive() -> null {
  let thread_id = ai.make_thread()

  handle {
    request ask(question) => {
      reply ai.ask(thread_id, question)
    }
  }

  child_agent()
}
```

`handle` ブロックが `let thread_id` をクロージャとして参照している。`let` バインディングは不変であるため、安全である。

### 段階的な能力追加

```katari
task orchestrator() -> null {
  handle {
    request log(msg) => {
      prim.log.info(msg)
      reply null
    }
  }

  // Phase 1: log のみで動作するワーカーを完了させる
  simple_worker()

  let thread_id = ai.make_thread()

  handle {
    request ask(question) => {
      reply ai.ask(thread_id, question)
    }
  }

  // Phase 2: log + ask の両方が使えるワーカーを並行実行
  par [
    { smart_worker_1() },
    { smart_worker_2() }
  ]
}
```

### 先着パターン (First-to-complete)

`-> never` の request を使い、最初に完了した結果を返すパターン:

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

`first_result` は `-> never` であるため、`never` 型の値を構成する `reply` は不可能であり、handler は必ず `break` する。最初に到着した request で break が発行され、もう一方のエージェントは terminate される。

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

各ワーカーが `report` request で結果を報告し、handle パラメータ `total` に集約される。全ワーカー完了後、`return` 節で集約結果を返す。

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

`cron.schedule` は外部サーバーが提供するタスクであり、毎日 0 時に `cron.notify` request を発生させる。handler は 30 回通知を受け取った後に `break` してタスクを終了する。
