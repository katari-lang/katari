---
title: 構文案 — 既存構文の保守的な改良
description: 第 4 版の構文を意味論を変えずに読みやすくする。inbox の公開を accepts に、event の配線を emits に、run 内の資源を with に、for の値を内包表記に
---

対象は `../syntax-requirements.md`。意味論は第 4 版（`../2026-10-02-spec.md`）のまま。

## 1. 既存構文の読みにくい点

| 箇所 | 問題 |
|---|---|
| `export receives Msg` | 「公開された受信」が 2 語の組み合わせで、export が他の宣言（state、use）の修飾と同じに見えるが、意味は「親が send できる」という interface の性質 |
| `receives` が header、`event E` が body | inbox と event は対になる interface なのに置き場が違う |
| `use x = M(args) => Tag` と `await x.send(m)` | 子との向きが 2 つあるのに、片方は宣言の末尾の記号、片方は run の文。「配線した子に send できない」が見た目で分からない |
| `=>` | 他の言語では lambda か match の矢印。宣言の末尾に付いた `=>` は「x が Tag を出す」と読めない |
| `use` | body の子 / resource、run のブロック資源、`for` の値の束縛、の 3 用途 |
| `use xs = for … { …; v }` | ブロックの最後の式が値、という C 系の書き方。子 1 つを集めるだけの用途が大半なのに `use c = …; c` が要る |
| `await sig` / `await receive()` / `await T(a)` | pool を待つ、inbox を待つ、tool を待つ、が同じ `await` |
| `receive { Tick(t) if t > due => t }` | ブロックと `=>` が match に見える |
| `external pay.charge   replace: forbidden   on_change: finish …` | 宣言の形が決まっていない。引数ごとの反応がどこに書かれるか分からない |

## 2. 提案

keyword: `component` `accepts` `inbox` `event` `emits` `export` `use` `state` `when` `for` `key` `run` `loop` `let` `await` `wait` `receive` `emit` `with` `par` `race` `finally` `tool` `fn` `external` `migration` `moved`

### 2.1 interface は header に、配線は宣言に

```
component Name(params) accepts Msg emits E {     accepts = 親が send できる inbox。emits = 自分が出す event
  inbox Msg                                       内部用の inbox（accepts と排他）。=> で配線した子の event だけが入る
  …
}
```

- `accepts Msg` が「公開 inbox」。`inbox Msg` が「内部 inbox」。1 つの component に片方だけ。`export receives` は無くなる
- `emits E` は header に置く。inbox と対になる interface なので、params と同じ行で読める

### 2.2 子の event を受ける配線は `emits`、send する子は `accepts` を持つ

```
use msgs  = discord.messages(ch) emits Received     msgs の event を Received として受ける。run は msgs を参照できない
use agent = Agent(model, tools)                     Agent は accepts を持つ。run から await agent.send(m) できる
```

- `=> Tag` を `emits Tag` に替える。宣言の末尾で「msgs emits Received」と読める
- 向きは宣言の形で決まる: `emits` 節が付いた子は受けるだけ、`accepts` を持つ子は送れる。両方は書けない（emits 節が付いた子を run が参照すると静的エラー）

### 2.3 run の中の資源は `with`

```
with typing = discord.typing(ch) { … }      ブロックの間だけ。body の use とは別の keyword
```

### 2.4 `for` の値は内包表記

```
use convs = Conversation(u, ch, model) for (u, _) in users key u      子 1 つを要素ごとに。convs : Map<UserId, Conversation>
for t in tickets key t.id { use triage = Triage(t); use log = Log(t) }  複数の宣言が要るときのブロック（値は持たない）
```

### 2.5 待つものを keyword で分ける

```
let x = await T(a)              tool の結果（Fault は伝播）。`await try T(a)` で Outcome
let m = receive                 inbox の次の 1 件
let ms = receive all            溜まっている全件
let t = receive Tick(t) if t > due    条件に合う最初の 1 件。合わないものは残る
wait pr                         pool が揃う / 真になるまで（Option なら Some、Bool なら真）
wait pr.merged
for await v in sig { … }        値が変わるたびに body をやり直す
```

- `await` は tool だけ。`receive` は inbox だけ。`wait` は pool だけ
- `receive` の pattern 形は match ではなく「条件に合う 1 件」なので、ブロックにしない

### 2.6 state の書き込みと event

```
s <- v        state を書く
emit e        自分の event を出す（header の emits E の値）
```

### 2.7 label

```
let x = await T(a)        label は x
await T(a) as sent        束縛しない await に名前を付ける（migration と plan が参照する）
```

### 2.8 外部 component の宣言

```
external discord.channel(name: Text restart, topic: Text update) -> { id: Text, send: tool(Text) ~> MessageId }
external discord.messages(ch: Channel restart, author: Option<UserId> restart) emits Message
external pay.charge(order: Order finish) ~> Receipt
  replace forbidden
  on restart interrupt
  on dispose detach
```

- 引数ごとの反応は引数の型の後ろに書く（`restart` / `update` / `finish`。省略は restart）
- 出力は `->`（resource の出力）、`~>`（tool の結果）、`emits`（event 源）で区別する
- 残りの宣言は本文に 1 行ずつ

### 2.9 migration

```
migration {
  Checkout state { old => { old with phase: migrate_phase(old.phase) } }
  Checkout run at charge { x } => charge { x }
  Bot inbox { old => { old with thread: none } }
  moved Support.Triage[*] => Support.Ticket[*]
}
```

## 3. 例

### 1. echo bot

```
component Echo(discord: Discord) {
  inbox Received(Message)
  use ch   = discord.channel("general")
  use msgs = discord.messages(ch) emits Received
  loop { let m = receive; await ch.send("echo: " ++ m.text) }
}
```

### 2. ターン制 bot

```
component Bot(discord: Discord, model: Model) {
  inbox Received(Message)
  use ch   = discord.channel("general")
  use msgs = discord.messages(ch) emits Received
  loop {
    let batch = receive all
    with typing = discord.typing(ch) { await ch.send(await ai.infer_text(model, prompt(batch))) }
  }
}
```

### 3. ユーザーごとの常駐

```
component Desk(discord: Discord, model: Model, clock: Clock) {
  inbox Seen(Message) | Tick(Timestamp)
  use ch    = discord.channel("help")
  use seen  = discord.messages(ch) emits Seen
  use ticks = time.every(clock, 1.day) emits Tick
  state users: Map<UserId, Timestamp> = {}
  use convs = Conversation(u, ch, model) for (u, _) in users key u
  loop {
    match receive {
      Seen(m) => users <- users.insert(m.author, m.at)
      Tick(t) => for (u, last) in users { if t - last > 30.days { users <- users.remove(u) } }
    }
  }
}

component Conversation(u: UserId, ch: Channel, model: Model) {
  inbox Received(Message)
  use mine = discord.messages(ch, author = u) emits Received
  state history: List<Msg> = []
  loop {
    history <- history ++ receive all
    let answer = await ai.infer_text(model, prompt(history))
    history <- history ++ [assistant(answer)]
    await ch.send(answer)
  }
}
```

### 4. 承認

```
component Request(req: Req, human: Human, exec: Executor, clock: Clock) {
  export state decision: Pending | Approved | Rejected | TimedOut = Pending
  run {
    match await race(human.ask(req, options = [Approve, Reject]), clock.after(3.days)) {
      Left(Approve) => { decision <- Approved; await exec.run(req) }
      Left(Reject)  => decision <- Rejected
      Right(_)      => decision <- TimedOut
    }
  } finally {
    if decision is Pending { await human.notify(req.author, "withdrawn") }
  }
}
```

### 5. PR パイプライン

```
component Feature(spec: Spec, gh: GitHub, model: Model, deploy: Deployer) {
  use branch = gh.branch(spec.repo, name = spec.slug)
  state phase: Implementing | Reviewing | Merged | Deployed = Implementing
  state feedback: List<Change> = []
  when phase is Reviewing { use pr = gh.pr(branch, title = spec.title) }
  run {
    loop {
      await Implement(model, spec, feedback, branch) as impl
      phase <- Reviewing
      match await Review(model, wait pr) {
        Approve    => { wait pr.merged; phase <- Merged; break }
        Changes(c) => feedback <- feedback ++ [c]
      }
    }
    await deploy.run(branch.sha) as deployed
    phase <- Deployed
  }
}
```

### 6. orchestrator

```
component Worker(model: Model, tools: Tools, task: Task) emits Done(TaskId, Text) {
  run { emit Done(task.id, await Turn(model, [user(task.prompt)], tools)) }
}

component Orchestrator(model: Model, tools: Tools, goal: Text) {
  inbox Done(TaskId, Text)
  export state results: Map<TaskId, Text> = {}
  state tasks: List<Task> = []
  use workers = Worker(model, tools, t) emits Done for t in tasks key t.id
  run {
    tasks <- await ai.infer_json(model, planning_prompt(goal), schema = List<Task>)
    loop { let Done(id, r) = receive; results <- results.insert(id, r) }
  }
}
```

### 7. 常駐 agent に send、返事は state

```
component Agent(model: Model, tools: Tools) accepts Msg {
  export state reply: Option<(Int, Text)> = None
  state history: List<Msg> = []
  state n: Int = 0
  loop {
    history <- history ++ receive all
    let t = await Turn(model, history, tools)
    history <- history ++ [assistant(t)]; n <- n + 1; reply <- Some((n, t))
  }
}

component Desk(discord: Discord, model: Model, kb: Knowledge) {
  inbox Received(Message)
  use ch    = discord.channel("help")
  use agent = Agent(model, { search = Search(kb, _) })        accepts を持つ。send できる。emits 節は無い
  use msgs  = discord.messages(ch) emits Received
  loop {
    let m = receive
    let before = agent.reply
    await agent.send(user(m.text))
    let (_, t) = wait agent.reply changed from before
    await ch.send(t)
  }
}
```

### 8. 動的 attach

```
component Plastic(spec: Text, env: Env, model: Model, ops: Human, args: I) {
  state cur: Option<(Text, Text)> = None
  when cur is Some((src, m)) { use d = link(src, env, I, migration = m); use app = d(args) }
  loop {
    let current = if cur is None then None else Some(wait d)
    let p = await Propose(model, spec, describe(I), env, current)
    if await ops.ask("apply?", p.diff) == Approve { cur <- Some((p.src, p.migration)) }
    for await _ in spec { break }
  }
}
```

### 9. 外部 component

```
external discord.channel(name: Text update, topic: Text update) -> { id: Text, send: tool(Text) ~> MessageId }
external discord.messages(ch: Channel update, author: Option<UserId> update) emits Message
external discord.typing(ch: Channel restart) -> {}
external pay.charge(order: Order finish) ~> Receipt
  replace forbidden
  on restart interrupt
```

### 10. migration

```
migration {
  Checkout state { old => { old with phase: if old.paid then Paid(old.receipt) else Cart } }
  Checkout run at charge { order } => charge { order }
  Bot inbox { old => { old with thread: none } }
  moved Support.Triage[*] => Support.Ticket[*]
}
```

## 4. 自己評価

- 読みやすさ: interface（accepts / emits）が header に揃い、配線（emits Tag）と send（accepts を持つ子）の向きが宣言の形で分かる。`await` / `receive` / `wait` の分離で run の各行が何を待つか読める
- 曖昧さ: `emits` が header（自分の event 型）と宣言の末尾（子の event の配線）の 2 か所に出る。意味は「出す側」で一貫しているが、初見で 2 つの用法に気付く必要がある。
  `wait agent.reply changed from before` は糖衣の形が未定で、`for await` の省略としてどう書くか決める必要がある
- 要件を満たせなかった点: 「配線した子に send しない」は静的検査で守られるが、構文だけでは防げない（`emits` 節の有無を見る）。
  `receive` の pattern 形で複数の条件を同時に待つ書き方（Erlang の複数 clause）は入れていない。要件 C-1 の範囲では 1 条件で足りる
