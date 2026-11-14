---
title: 構文案: minimal
description: keyword と構文の数を最小にした案。宣言は `name = 式` の 1 形、通信は矢印 2 つ、待つのは `await` と `watch`
---

## 1. 概要

3 文:

1. component は `name = 式` の宣言の集合と、1 つの逐次ブロック `run { }` からなる。宣言は React のコンポーネント本体のように runtime が差分で init / update / dispose する。
2. 通信は矢印 2 つだけ。宣言行の末尾の `-> Tag` は子の event を自分の inbox に流す配線、逐次の `child <- Msg` は inbox への send（`parent <- Ev` が自分の event の送出）。signature の `(params) <- Inbox -> Event` も同じ矢印。
3. 逐次で止まるのは `await`（tool 呼び出し、inbox）と `watch { }`（pool が変わるたびにやり直す loop）。local は `let`（不変）、state は `var`。

### keyword 一覧（26）

| 分類 | keyword | 借りた元 |
| --- | --- | --- |
| 定義 | `component` `declare` `fn` `async` `migrate` `moved` | TS `declare`、JS `async fn`、terraform `moved` |
| 宣言 | `var` `export` `run` `loop` `for` `in` `key` `if` `else` | Kotlin `var`、JS `export`、React `key` |
| 逐次 | `let` `await` `use` `watch` `match` `try` `catch` `finally` `throw` `break` | JS、C# `using`、Kotlin `use` |

組み込みの名前（keyword ではない。予約名）: `inbox` `parent` `old` `all` `race` `outcome` `null`

記号: `->`（配線 / 出力の向き）、`<-`（send / 入力の向き）、`=>`（lambda と match arm）、`label@`（await 位置の名前、Kotlin のラベル）

### 宣言と逐次の見分け方

- 宣言は `name = 式` の行（修飾は `var` / `export` のみ）。`let` `await` `<-` は宣言には現れない
- 逐次は `run { }` `loop { }` `async fn { }` の中だけ
- `if` と `for` は両方に出るが、宣言側では必ず `name = if …` / `name = for …` の右辺（値を持つ式）。裸の `if` / `for` は逐次
- 子は `name = Child(args)`、配線した子はその行の末尾に `-> Tag` が付く。付いていない子にだけ `<-` できる

## 2. 要件ごとの表現

### A. component 定義

| | 表現 | 例 |
| --- | --- | --- |
| A1 | signature の params。時変（pool）として読む | `component Conversation(user: String, channel_id: String) { … }` |
| A2 | body は `name = 式` の集合。順序なし | `channel = discord.channel(id = channel_id)` |
| A3 | `export` を付けた宣言の record が出力。無ければ Unit | `export var reply: String? = null` |
| A4 | **公開 inbox は signature の `<-`**。`<-` が無い component の inbox は配線 tag だけで構成される内部用 | `component Agent(system: String) <- Ask(String) \| Reset { … }` |
| A5 | event 型は signature の `->` | `component Worker(task: Task) -> Finished(Result) { … }` |

A4 の補足: inbox の message 型は宣言しない。`<-` の直和（公開分）と、body の `-> Tag` 配線が作る構成子 `Tag(子の event)`（内部分）の和が inbox 型になる。親が send できるかは signature に `<-` があるかだけで読める。

```
component Agent(system: String) <- Ask(String) -> Replied(String) {   // 親は Ask を send できる。Replied は event
  …
}
component Echo(channel_id: String) {                                   // inbox は内部用。親は send できない
  channel = discord.channel(id = channel_id) -> Msg                    // inbox の構成子 Msg(discord の event) が生える
  …
}
```

### B. 宣言

| | 表現 | 例 |
| --- | --- | --- |
| B1 | `name = Child(args)`。key は末尾の `key 式` | `idle = time.after(30.days) key last_seen` |
| B2 | 配線は宣言行末尾の `-> Tag`。**`-> Tag` のある子には `<-` できず、run も読めない（静的エラー）** | `channel = discord.channel(id = channel_id) -> Msg` / `agent = Agent(system = s)`（send する子） |
| B3 | `var name: T = 初期値` | `var history: List<String> = []` |
| B4 | `name = if 条件 { 宣言…; 最後の式 }`。値は `T?`（偽の間は `null`） | `pr = if reviewing { github.pr(repo = repo, head = branch.name) }` |
| B5 | `name = for x in 集合 key 式 { 宣言…; 最後の式 }`。値は `Map<Key, T>` | `convs = for u in users key u { Conversation(user = u) }` |
| B6 | `export` を `var` / 子 / tool 値の宣言に前置 | `export search = tavily.search(limit = 5)` |
| B7 | `run { … }` を 1 つ。`loop { … }` は `run { loop { … } }` の省略 | `loop { let m = await inbox.next(); … }` |

B2 の見た目:

```
channel = discord.channel(id = channel_id) -> Msg     // 配線した子。行末に矢印。run からは触れない
agent   = Agent(system = "…")                         // send する子。矢印なし。run で agent <- Ask(q)、agent.reply を読む
convs   = for u in users key u { Conversation(user = u) } -> Left   // 集合の配線。inbox には Left(key, event) が入る
```

### C. run の中

| | 表現 |
| --- | --- |
| C1 | `await inbox.next()`（次の 1 件）、`await inbox.all()`（1 件以上溜まるまで待ち全件）、`await inbox.first { Reply(r) if r.id == id => r }`（合う最初の 1 件。合わないものは残る） |
| C2 | `parent <- Done(result)` |
| C3 | `agent <- Ask(q)`（`->` の無い子にだけ書ける） |
| C4 | `let r = await search(q)`（Fault は伝播）。`let o = await outcome(search(q))` で Outcome を受ける |
| C5 | `watch { … }`。body が読んだ pool の値が変わるたびに body を中断してやり直す。`break 値` で抜ける |
| C6 | `history = history + m`（`var` にだけ書ける。`let` には書けない） |
| C7 | `use typing = discord.typing(channel = c) { … }`（ブロックを抜けると dispose） |
| C8 | `await all(a = f(x), b = g(y))`、`await race(a = f(x), b = g(y))`。動的個数は `await all(for t in tasks key t.id { solve(t) })` |
| C9 | `loop` `for x in xs` `break` `match v { Pat => … }` `try { } catch (e) { } throw Fault(…)` |
| C10 | `run { try { … } finally { … } }`（finally は完走・失敗・cancel の全てで走る。専用構文なし） |
| C11 | `let` は不変。可変は `var`（state）だけ |

tool 呼び出しの規則: `f(args)` は **呼ばずに tool 値を作る**。`await` して初めて走る。`all` / `race` / `outcome` は tool 値を受け取る普通の tool。

```
let r = await search(q)                        // 走る
let s = search(q)                              // tool 値（AI に渡せる、all に渡せる）
match await race(Answer = human.ask(q), Timeout = time.sleep(3.days)) {
  Answer(a)  => a.text
  Timeout(_) => "timeout"
}
```

### D. tool と純粋関数

| | 表現 |
| --- | --- |
| D1 | トップレベルの `async fn name(args): T { 逐次 body; 最後の式 }` |
| D2 | 名前付き引数の一部だけ与えた呼び出し `search(limit = 5)`。残りの引数が schema になる |
| D3 | `fn name(args): T = 式` または `{ … }`（`await` が書けない） |
| D4 | **component の中に書いた `async fn`** は手続き。run から `await remember(m)` で inline に走り、state を書ける。値にならず export できない。React で component の中に書いた handler と同じ位置づけ |

```
async fn summarize(text: String): String {           // tool（event を 1 回出す component の糖衣）
  let r = await llm.chat(prompt = "要約: " + text)
  r.text
}
fn greet(name: String): String = "hi " + name        // 純粋関数

component Bot(c: String) {
  var history: List<String> = []
  async fn remember(text: String) { history = history + text }   // 手続き。state を書く
  loop {
    let Msg(Posted(m)) = await inbox.next()
    await remember(m.text)
  }
}
```

### E. 外部 component

`declare component` は body に型と lifecycle 設定だけを書く（`name = 値` の宣言。terraform の `lifecycle` ブロックと同じ発想）。

```
declare component discord.channel(id: String, author: String?) -> Posted(discord.Message) {
  export id: String
  export name: String
  update  = [author]        // author の差し替えは接続を保ったまま update
  restart = [id]            // id の差し替えは dispose → init
  on_restart = reconnect    // runtime 再起動時は再接続して続行
  dispose = unsubscribe     // dispose は購読解除。外部に副作用なし
}
```

### F. migration

`migrate Name { … }` の body も宣言の集合。`old` は旧 state / locals の record。

| | 表現 |
| --- | --- |
| F1 state | `messages: List<String> = old.history.map(m => m.text)` |
| F1 run の位置 | `wait_answer@ { question = old.q }`（新 label の locals を旧 locals から作る） |
| F1 inbox | `inbox = m => match m { Reply(r) => Answer(r.text) }` |
| F1 改名 | `moved history -> messages`（state / 子 / label / tag すべて同じ形） |
| F2 | 逐次の await 位置に `label@` を前置。`ask@ let r = await human.ask(q)` |

## 3. 例

### 3.1 echo bot

```
declare component discord.channel(id: String, author: String?) -> Posted(discord.Message) { … }
declare async fn discord.post(channel: String, text: String): Unit

component Echo(channel_id: String) {
  channel = discord.channel(id = channel_id) -> Msg
  loop {
    let Msg(Posted(m)) = await inbox.next()
    await discord.post(channel = channel_id, text = m.text)
  }
}
```

### 3.2 ターン制 bot

```
component TurnBot(channel_id: String) {
  channel = discord.channel(id = channel_id) -> Msg
  var history: List<String> = []
  loop {
    let batch = await inbox.all()
    history = history + batch.map((Msg(Posted(m))) => m.text)
    use typing = discord.typing(channel = channel_id) {
      let answer = await llm.chat(history = history)
      await discord.post(channel = channel_id, text = answer)
      history = history + answer
    }
  }
}
```

### 3.3 ユーザーごとの常駐

```
component Host(channel_id: String) {
  channel = discord.channel(id = channel_id) -> Msg
  var users: Set<String> = {}
  convs = for u in users key u { Conversation(user = u, channel_id = channel_id) } -> Left
  loop {
    match await inbox.next() {
      Msg(Posted(m))   => users = users + m.author
      Left(u, Gone(_)) => users = users - u
    }
  }
}

component Conversation(user: String, channel_id: String) -> Gone(String) {
  channel = discord.channel(id = channel_id, author = user) -> Msg     // 自分の分だけ購読
  var last_seen: Instant = now()
  idle = time.after(30.days) key last_seen -> Idle                      // last_seen が変わるたびに作り直す
  var history: List<String> = []
  loop {
    match await inbox.next() {
      Msg(Posted(m)) => {
        last_seen = now()
        history = history + m.text
        await discord.post(channel = channel_id, text = await llm.chat(history = history))
      }
      Idle(_) => {
        parent <- Gone(user)
        break
      }
    }
  }
}
```

### 3.4 承認

```
component Approval(channel: String, question: String) -> Decided(Boolean) {
  var decided = false
  run {
    try {
      ask@ let r = await race(
        Answer  = human.ask(channel = channel, question = question),
        Timeout = time.sleep(3.days),
      )
      decided = true
      parent <- Decided(match r { Answer(a) => a.approved, Timeout(_) => false })
    } finally {
      if !decided {
        await discord.post(channel = channel, text = "取り下げ: " + question)
      }
    }
  }
}
```

### 3.5 PR パイプライン

```
component Pipeline(repo: String, issue: Issue) -> Merged(String) {
  branch = github.branch(repo = repo, name = "issue-" + issue.id)      // component と同じ寿命
  var reviewing = false
  pr = if reviewing { github.pr(repo = repo, head = branch.name, base = "main") }   // レビュー中だけ存在
  run {
    await codegen(branch = branch.name, issue = issue)
    reviewing = true
    let open = watch { if pr != null { break pr } }                      // PR ができるまで
    loop {
      let review = await reviewer(pr = open.number)
      if review.approved { break }
      await codegen(branch = branch.name, issue = issue, feedback = review.comments)
    }
    watch { if open.merged { break } }                                   // merge を待つ
    reviewing = false
    parent <- Merged(open.url)
  }
}
```

### 3.6 orchestrator

```
component Worker(task: Task) -> Finished(Result) {
  run {
    let r = await solve(task = task)
    parent <- Finished(r)
  }
}

component Orchestrator(goal: String) -> Completed(Map<String, Result>) {
  var tasks: List<Task> = []
  var results: Map<String, Result> = {}
  workers = for t in tasks key t.id { Worker(task = t) } -> Done
  run {
    tasks = await plan(goal = goal)
    loop {
      let Done(id, Finished(r)) = await inbox.next()
      results = results.put(id, r)
      if results.size == tasks.size { break }
    }
    parent <- Completed(results)
  }
}
```

### 3.7 常駐 agent に send して state で返事を読む

```
component Agent(system: String) <- Ask(String) {       // <- があるので親は send できる
  export var reply: String? = null
  loop {
    let Ask(q) = await inbox.next()
    reply = await llm.chat(system = system, prompt = q)
  }
}

component Caller() {
  agent = Agent(system = "you are terse")              // 矢印なし = send する子。event は受けない
  run {
    agent <- Ask("hi")
    let r = watch { if agent.reply != null { break agent.reply } }
    await discord.post(channel = "log", text = r)
  }
}
```

### 3.8 動的 attach

```
component Attach(spec: String) {
  var source: Source? = null
  var approved = false
  approval = if source != null && !approved {
    Approval(channel = "ops", question = "link " + spec + "?")
  } -> Verdict
  plugin = if source != null && approved { katari.link(source = source) }
  run {
    source = await generate(spec = spec)
    let Verdict(Decided(ok)) = await inbox.next()
    if !ok { throw Fault("rejected") }
    approved = true
    let p = watch { if plugin != null { break plugin } }
    await discord.post(channel = "ops", text = "linked " + p.address)
  }
}
```

### 3.9 外部 component の宣言

```
declare component discord.channel(id: String, author: String?) -> Posted(discord.Message) {
  export id: String
  export name: String
  update  = [author]
  restart = [id]
  on_restart = reconnect
  dispose = unsubscribe
}

declare component pay.charge(amount: Int, customer: String) -> Charged(Receipt) {
  export receipt: Receipt?
  finish  = [amount, customer]    // init 後の引数差し替えは finish（作り直さない）
  replace = false                 // 同じ address での作り直し禁止
  on_restart = resume             // 再起動時は外部の状態を照会して続行
  dispose = keep                  // dispose しても課金は取り消さない
}
```

### 3.10 migration

```
// 旧: var history: List<Message>、ask@ let r = await human.ask(q)、inbox の構成子 Reply(Reply)
// 新: var messages: List<String>、wait_answer@ let r = await human.ask(q)、構成子 Answer(String)
migrate Conversation {
  moved history -> messages                              // 改名
  messages: List<String> = old.history.map(m => m.text)  // state の型変更
  moved ask@ -> wait_answer@                             // run の位置の改名
  wait_answer@ { question = old.q, asked_at = now() }    // 位置の locals
  inbox = m => match m { Reply(r) => Answer(r.text) }    // 溜まっている message の変換
}
migrate Host {
  moved convs -> conversations                           // 子の改名（address の付け替え）
}
```

## 4. 自己評価

### 読みやすさ

- 宣言が `name = 式` の 1 形で、修飾が `var` / `export` の 2 つだけ。配線は行末の `-> Tag` だけなので、子の一覧を縦に見れば「配線した子」と「send する子」が矢印の有無で分かる
- A4 は signature の `<-` の有無で読める。inbox 型を別に宣言しないので、配線を増やしたとき inbox 型を直す手間がない
- `async fn` / `fn` / `let` / `await` / `try` / `finally` / `export` / `key` は読者の既知語。新語は `watch` と `declare component` の lifecycle 項目くらい
- 3.1 は 6 行で書ける

### 曖昧さ

- `->` が 3 箇所で使われる（signature の event 型、配線、`moved a -> b`）。「a の出力が b へ行く」で統一しているが、`moved` の矢印は別物に見える
- component 内の `async fn` と トップレベルの `async fn` で意味が変わる（手続き / tool）。React の handler と module 関数の違いと同じだが、Katari を知らない読者には説明が要る
- 宣言側の `name = if …` と逐次の `if` は字面が同じで、文脈（`run` の内外）でしか区別できない。`for` も同じ
- `f(args)` が「呼ばずに tool 値を作る」規則は、JS の `f()` が即実行される直感とずれる。`await` を忘れた行が静かに tool 値を捨てる（未使用 tool 値を静的エラーにすれば回避できる）
- 部分適用 `search(limit = 5)` と、省略可能な引数（`T?`）を省いた完全な呼び出しが見た目で区別できない。省略可能引数は schema に残す規則にすれば一意になる
- `for` を配線したとき inbox に入るのが `Tag(key, event)`（2 引数）、単体の子は `Tag(event)`（1 引数）で、tag の arity が宣言形で変わる

### 要件を満たせなかった / 弱い点

- C5 の「条件を満たすまで待つ」は `watch { if c { break } }` で書けるが、1 行の省略形が無い。`await until(c)` のような library 関数を足すなら tool 値規則との整合（`c` は式であり tool 値ではない）が必要
- E2 の lifecycle 項目（`update` / `restart` / `finish` / `replace` / `on_restart` / `dispose`）は固定名の `name = 値` で書いたが、値の語彙（`reconnect` / `resume` / `keep` …）は provider 側の意味論次第で、構文としては未確定
- F1 の run 位置変換は label の locals 変換だけを書いた。「label A から label B へ位置を移す」（A は消えた）は `moved A@ -> B@` で表したが、移った先で locals が足りないときの既定値が無い
- B4 の `if` ブロック内に複数の子を宣言した場合、外から見える値は最後の式だけ。内側の子は address は持つが、run から名前で読む形を書いていない（`pr.inner` のような record 化が要る）
- `_` を pattern で使っている（制約の `_` 禁止は宣言名についてのものと読んだ）
