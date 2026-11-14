---
title: 構文案: HCL 風
description: 宣言部は terraform のブロックとラベル、run は普通の async 言語。矢印の向きで通信の向きを表す
---

意味論は `2026-10-02-spec.md` に従う。ここでは表層だけを示す。

## 1. 概要

3 文で説明する。

1. component は `種類 "名前" { 属性 }` 形の宣言の集合（terraform の resource）と、1 つの `run { }`（async 関数）からなる。runtime は宣言を差分で reconcile する
2. 通信の向きは矢印で書く。ヘッダの `-> Event` が自分の出す event、`<- Message` が親から send される message。宣言の `子 "名前" -> Tag { }` は子の event を自分の inbox に流す配線で、run の `子.send(..)` は子の inbox への送信。1 つの子にはどちらか一方しか書けない
3. run の中の `await` 位置には JS のラベル `name:` を付けられ、migration と plan がそれを参照する

### keyword

```
component tool fn step extern migration
state export when for in key
run loop let await emit return
if else match break try catch throw finally
```

ブロック種類名（`lifecycle` `moved` `label` `inbox` `output` など）は keyword ではなく、その文脈でだけ意味を持つ名前。

### 宣言と逐次の見分け方

- `識別子 "ラベル" { ... }` の形（ラベルが文字列）は宣言。ラベルが address になる。`for` `key` `-> Tag` はラベルの後ろに付く
- `run { }` / `loop { }` の中は逐次。文は改行区切り、値は `let` に束縛、`await` が待ち
- 宣言の中の `name = expr` は属性（時変の値）。run の中の `name = expr` は state への書き込み
- 定義（`component` `tool` `fn` `step` `extern`）は裸の識別子で名付ける。インスタンス（宣言）は文字列ラベルで名付ける。terraform の resource type と name の関係と同じ

```hcl
component Echo(channel: String) -> Done {        # 定義: 裸の識別子
  discord.messages "feed" -> Msg {                # 宣言: 文字列ラベル、矢印は配線
    channel = channel
  }
  loop {                                          # 逐次
    let Msg(m) = await inbox.next()
    await discord.post(channel = channel, text = m.text)
  }
}
```

## 2. 要件ごとの表現

### A. component 定義

| 要件 | 表現 |
|---|---|
| A1 名前と params | `component Name(a: T, b: U) { }`。params は時変 |
| A2 body は宣言の集合 | `{ }` の中に宣言を順序なしで並べる |
| A3 出力 = export の直積 | `export` を付けた宣言の名前でレコードになる。無ければ Unit |
| A4 inbox の型と公開 | 公開（親が send できる）構成子はヘッダの `<- Ask(text: String) \| Reset` に書く。内部用の構成子は配線 `-> Tag` から導かれ、ヘッダには現れない |
| A5 自分の event | ヘッダの `-> Done(result: String) \| Failed(reason: String)` |

```hcl
# 公開 inbox あり: 親は agent.send(Ask(..)) できる
component Agent(system: String) <- Ask(text: String) | Reset {
  export state "replies": List<String> = []
  ...
}

# 公開 inbox なし: ヘッダに <- が無い。inbox は配線で決まる内部用の直和 Msg | Tick
component Watcher(channel: String) -> Alert(text: String) {
  discord.messages "feed" -> Msg { channel = channel }
  time.ticker "tick" -> Tick { every = 1h }
  ...
}
```

公開の有無はヘッダの `<-` の有無で読める。`export` は出力の印に限る。

### B. 宣言

| 要件 | 表現 |
|---|---|
| B1 子 / resource | `Type "name" { attr = expr }`。key の上書きは `Type "name" key expr { }` |
| B2 配線 | `Type "name" -> Tag { }`。`-> Tag` を付けた子は run から参照できない（静的エラー）。付けない子は run から `name.send(..)` と pool 読みができる |
| B3 state | `state "name": T = init`。書けるのは run の `name = expr` だけ |
| B4 条件付き | `when cond { 宣言... }`。cond が真の間だけ中の宣言が存在する |
| B5 集合 | `Type "name" for x in xs key f(x) { }`。`name` は `Map<Key, Output>` |
| B6 export | 宣言の前に `export`。`export state`、`export Type "name"`、`export tool "name" = ...` |
| B7 run | `run { }` が 1 つ。`loop { }` を body に直接書くと `run { loop { } }` の略 |

B2 の見た目。配線した子は矢印が付く。send する子は矢印が無い。

```hcl
discord.messages "feed" -> Msg { channel = channel }   # 配線: 自分の inbox に Msg(m) が入る。run は feed に触れない
Agent "agent" { system = system }                      # send 先: run で agent.send(Ask(..))、agent.replies を読む
```

同じ子に両方は書けない。`-> Tag` があれば `send` は静的エラー、`-> Tag` が無ければその子の event は捨てられる（Tag が無いので受けようがない）。

B1 の key と B5。

```hcl
Approval "approval" key request.id { request = request }   # request.id が変わると作り直し
Conversation "conv" for user in users key user { user = user }
```

### C. run の中

| 要件 | 表現 |
|---|---|
| C1 受信 | `await inbox.next()` / `await inbox.all()` / `await inbox.first(Reply(r) if r.id == id)` |
| C2 event | `emit Done(result = r)` |
| C3 send | `agent.send(Ask(text = t))` |
| C4 tool 呼び出し | `let r = await search(query = q)`。Fault は throw される。Outcome のまま受けるのは `let o = await settle(search(query = q))` |
| C5 pool 待ち | `await until(pr?.merged == true)`。値が変わるたびに body をやり直すのは `for await v in expr { }`（collectLatest。body が走っている間に値が変わると cancel して再実行） |
| C6 state 書き込み | `users = users.add(id)` |
| C7 ブロック限定の resource | run の中に宣言をそのまま書く。囲むブロックを抜けると dispose される |
| C8 並列 | `await all(a = f(), b = g())` はレコード、`await race(A = f(), B = g())` は直和。動的個数は `await all(for t in tasks key t.id { await f(t) })` |
| C9 制御 | `loop` `for x in xs` `break` `match v { Pat -> expr }` `try { } catch e { }` `throw Fault(..)` |
| C10 finally | `run { } finally { }` |
| C11 局所変数 | `let x = expr`。再代入不可。`=` だけの代入は state |

```hcl
run {
  ask: let answer = await human.ask(user = u, question = q)     # await 位置のラベル (F2)
  let (lint, test) = await all(lint = ci.lint(), test = ci.test())
  match await race(Got = inbox.next(), Idle = time.sleep(30d)) {
    Got(Msg(m)) -> history = history.push(m.text)
    Idle        -> break
  }
  discord.typing "typing" { channel = channel }                 # C7: このブロックの間だけ
  for await a in agent.answers { if a.length > 0 { break } }   # C5: collectLatest
} finally {
  await slack.post(channel = u, text = "終了")
}
```

### D. tool と純粋関数

| 要件 | 表現 |
|---|---|
| D1 tool 定義 | `tool name(a: T) -> R { 逐次 body; return r }` |
| D2 tool 値 | `tool "name" = search(index = idx)`。宣言の文脈では tool に一部の引数を与えた式は実行されず tool 値になる |
| D3 純粋関数 | `fn name(a: T) -> R = expr` または `{ }` |
| D4 inline 手続き | component の中の `step name(a: T) { }`。run から `await name(x)` で呼ぶ。state を書ける。値にならない |

```hcl
tool summarize(text: String) -> String {
  let r = await ai.chat(messages = [text])
  return r.text
}

fn is_idle(last: Time, now: Time) -> Bool = now - last > 30d

component Conversation(user: UserId) {
  state "history": List<String> = []
  export tool "lookup" = search(index = user)         # AI に渡す tool 値
  step remember(text: String) { history = history.push(text) }
  ...
}
```

### E. 外部 component

| 要件 | 表現 |
|---|---|
| E1 型宣言 | `extern pkg.name(a: T) <- M -> E { output { x: T } }` |
| E2 静的な振る舞い | `lifecycle { }` ブロック。引数名ごとに `update` / `restart` / `forbid`、`emits = finish`、`restart = reattach \| resume \| rerun`、`dispose = delete \| keep` |

例は 3 章の 9 に置く。

### F. migration

| 要件 | 表現 |
|---|---|
| F1 state の変換 | `state "name" (old: T0) -> T1 { expr }` |
| F1 run 位置の変換 | `label "old" to "new" (old: Locals0) -> Locals1 { expr }` |
| F1 inbox の変換 | `inbox (old: Inbox0) -> Inbox1 { match old { .. } }` |
| F1 改名 | `moved { from = old_name, to = new_name }`（terraform と同じ） |
| F2 await 位置の名前 | run の文に `name:` を前置する。JS のラベル文 |

```hcl
migration "reply-as-record" {
  component Agent {
    moved { from = general, to = channel }
    state "reply" (old: String?) -> Reply? {
      old == null ? null : Reply { text = old, at = 0 }
    }
    label "ask" to "ask_human" (old: { question: String }) -> { question: String, user: UserId } {
      { question = old.question, user = default_user }
    }
    inbox (old: Inbox0) -> Inbox {
      match old {
        Reply(t) -> Reply(Reply { text = t, at = 0 })
        other    -> other
      }
    }
  }
}
```

## 3. 例

### 1. echo bot

```hcl
component EchoBot(guild: String, channel_name: String) {
  discord.channel "general" {
    guild = guild
    name  = channel_name
  }
  discord.messages "feed" -> Msg {
    channel = general.id
  }

  loop {
    let Msg(m) = await inbox.next()
    await discord.post(channel = general.id, text = m.text)
  }
}
```

### 2. ターン制 bot

```hcl
component TurnBot(channel: String, system: String) {
  discord.messages "feed" -> Msg { channel = channel }

  loop {
    let batch = await inbox.all()
    discord.typing "typing" { channel = channel }        # この周回の間だけ存在する
    let reply = await ai.chat(
      system   = system,
      messages = batch.map(Msg(m) => m.text),
    )
    await discord.post(channel = channel, text = reply)
  }
}
```

### 3. ユーザーごとの常駐

```hcl
component Lobby(channel: String) {
  discord.messages "feed" -> Seen { channel = channel }
  state "users": List<UserId> = []

  Conversation "conv" for user in users key user -> Left {
    channel = channel
    user    = user
  }

  loop {
    match await inbox.next() {
      Seen(m)          -> users = users.add(m.author)
      Left(Gone(user)) -> users = users.remove(user)
    }
  }
}

component Conversation(channel: String, user: UserId) -> Gone(user: UserId) {
  discord.messages "mine" -> Msg {
    channel = channel
    author  = user
  }
  state "history": List<String> = []

  loop {
    match await race(Got = inbox.next(), Idle = time.sleep(30d)) {
      Got(Msg(m)) -> {
        history = history.push(m.text)
        let reply = await ai.chat(messages = history)
        await discord.post(channel = channel, text = reply)
      }
      Idle -> {
        emit Gone(user = user)
        break
      }
    }
  }
}
```

### 4. 承認

```hcl
component Approval(request: Request, approver: UserId) -> Decided(ok: Bool) {
  state "decided": Bool = false

  run {
    ask: let result = await race(
      Answer  = human.ask(user = approver, question = request.summary),
      Timeout = time.sleep(3d),
    )
    decided = true
    emit Decided(ok = match result {
      Answer(a) -> a.yes
      Timeout   -> false
    })
  } finally {
    if !decided {
      await slack.post(channel = approver, text = "取り下げ: ${request.summary}")
    }
  }
}
```

親側。`key request.id` で request が変わると作り直され、古い方の finally が走る。

```hcl
Approval "approval" key request.id -> Decision { request = request, approver = lead }
```

### 5. PR パイプライン

```hcl
component Pipeline(repo: String, change: Change) -> Merged(sha: String) {
  github.branch "branch" {
    repo = repo
    name = "katari/${change.id}"
  }
  state "reviewing": Bool = false

  when reviewing {
    github.pr "pr" {
      repo  = repo
      head  = branch.name
      title = change.title
    }
  }

  run {
    await git.push(branch = branch.name, change = change)
    reviewing = true
    opened: await until(pr != null)
    loop {
      let review = await ai.review(url = pr?.url)
      if review.approved { break }
      await git.push(branch = branch.name, change = await ai.fix(review = review))
    }
    merged: await until(pr?.merged == true)
    let sha = pr?.merged_sha
    reviewing = false
    emit Merged(sha = sha)
  }
}
```

### 6. orchestrator

```hcl
component Orchestrator(goal: String) -> Finished(results: Map<TaskId, String>) {
  state "tasks": List<Task> = []
  state "results": Map<TaskId, String> = {}

  Worker "worker" for task in tasks key task.id -> Work {
    task = task
  }

  run {
    plan: tasks = await ai.plan(goal = goal)
    for task in tasks {
      let Work(Done(id, result)) = await inbox.next()
      results = results.put(id, result)
    }
    emit Finished(results = results)
  }
}

component Worker(task: Task) -> Done(id: TaskId, result: String) {
  run {
    let result = await ai.work(task = task)
    emit Done(id = task.id, result = result)
  }
}
```

### 7. 常駐 agent に send して返事を state で読む

```hcl
component Agent(system: String) <- Ask(text: String) {
  export state "replies": List<String> = []

  loop {
    let Ask(text) = await inbox.next()
    let r = await ai.chat(system = system, messages = [text])
    replies = replies.push(r)
  }
}

component Parent(system: String) {
  Agent "agent" { system = system }           # 矢印なし: send する子。agent の event は受けない

  run {
    agent.send(Ask(text = "hello"))
    first: await until(agent.replies.length >= 1)
    agent.send(Ask(text = "and then?"))
    second: await until(agent.replies.length >= 2)
    await slack.post(channel = "log", text = agent.replies.join("\n"))
  }
}
```

### 8. 動的 attach

```hcl
component Extend(spec: String, reviewer: UserId) {
  state "approved": String? = null

  when approved != null {
    katari.link "plugin" -> Plugin {
      source = approved
    }
  }

  run {
    let source = await ai.generate_katari(spec = spec)
    approve: let ok = await human.ask(
      user     = reviewer,
      question = "これを link してよいか\n```\n${source}\n```",
    )
    if !ok { return }
    approved = source
    loop {
      let Plugin(e) = await inbox.next()
      await slack.post(channel = "log", text = "plugin: ${e}")
    }
  }
}
```

### 9. 外部 component の宣言

```hcl
extern discord.channel(guild: String, name: String) -> Deleted {
  output { id: String }
  lifecycle {
    guild   = restart        # guild が変わると dispose して作り直す
    name    = update         # name は in-place で更新
    restart = reattach       # runtime 再起動時は既存 channel に再接続
    dispose = delete         # dispose は channel の削除
  }
}

extern pay.charge(customer: String, amount: Money) -> Charged(id: String) {
  lifecycle {
    customer = forbid        # replace 禁止。plan でエラー
    amount   = forbid
    emits    = finish        # Charged を出したら完了。以後 params の変更は無視
    restart  = resume        # runtime 再起動時は provider 側の進行を引き継ぐ
    dispose  = keep          # dispose しても返金しない
  }
}
```

### 10. migration

変更前。

```hcl
component Agent(system: String) <- Ask(text: String) {
  discord.channel "general" { guild = g, name = "general" }
  export state "reply": String? = null
  loop {
    let Ask(text) = await inbox.next()
    ask: reply = await ai.chat(system = system, messages = [text])
  }
}
```

変更後。state を record に、`general` を `channel` に改名、ラベル `ask` を `ask_human` に変えて locals を増やした。

```hcl
component Agent(system: String, default_user: UserId) <- Ask(text: String) {
  discord.channel "channel" { guild = g, name = "general" }
  export state "reply": Reply? = null
  loop {
    let Ask(text) = await inbox.next()
    ask_human: let r = await ai.chat(system = system, messages = [text], user = default_user)
    reply = Reply { text = r, at = time.now() }
  }
}
```

migration。

```hcl
migration "reply-as-record" {
  component Agent {
    moved { from = general, to = channel }
    state "reply" (old: String?) -> Reply? {
      old == null ? null : Reply { text = old, at = 0 }
    }
    label "ask" to "ask_human" (old: { text: String }) -> { text: String, user: UserId } {
      { text = old.text, user = default_user }
    }
    inbox (old: Inbox0) -> Inbox {
      old                                  # Ask の形は変わっていない
    }
  }
}
```

## 4. 自己評価

### 読みやすさ

- 宣言はすべて `Type "name" { }` で、terraform を知っていればそのまま読める。run は async/await の言語に見える。2 つは字面で混ざらない
- 通信の向きが矢印に集約されている。ヘッダの `<-` と `->`、配線の `-> Tag`、run の `.send(`。「配線した子に send しない」「send する子から event を受けない」は `-> Tag` の有無で決まり、違反は静的エラーで済む
- 公開 inbox はヘッダの `<-` に出る。`export receives` のような二重の修飾が要らない
- ラベルは JS のラベル文、改名は terraform の `moved`、lifecycle は terraform の `lifecycle`。借用元が明確

### 曖昧さ

- 内部用 inbox の全体像は、ヘッダの `<-` と body 中の `-> Tag` を集めないと分からない。1 画面に収まらない component では読み落とす
- 配線の Tag は子の event 直和をそのまま包むので、`Work(Done(id, result))` のように 2 段になる。子の event が 1 構成子のときに平たくする糖衣（`-> Tag.*` など）は未定義
- run の中に書いた宣言（C7）は、見た目が body の宣言と同じで、寿命だけが違う。「宣言の集合と逐次コードは見た目で区別できる」に対しては、宣言の形は一貫しているが位置で寿命が変わる、という答えになる
- 宣言の文脈で `search(index = idx)` が tool 値、run の文脈で `await search(..)` が呼び出し。同じ形が文脈で意味を変える
- `when` の中の子は pool では optional になる（`pr?.url`）。`until(pr != null)` の後も `?.` が要る。flow typing を入れるかどうかは未定
- `race(A = .., B = ..)` の引数名が直和の構成子になる規則は、知らないと読めない
- `=` が宣言では属性、run では state 書き込み。`let` の有無で局所変数と区別するが、`let` を忘れると未宣言 state の静的エラーになるだけなので実害は小さい

### 満たせなかった点

- B2 の「配線した子に run が依存できない」は構文ではなく静的検査に頼っている。`-> Tag` の子を run が名前で触ると静的エラー、という形。構文的に名前を見えなくする案（配線した子にラベルを付けない）は、address の要件と衝突するので採らなかった
- A4 で、親から send される構成子と、配線から入る構成子が同じ直和に混ざるとき、ヘッダの `<-` 側に書いた構成子を配線の Tag にも使えるかどうかを決めていない。使えないとするのが単純
- E2 の `emits = finish` は「出力 event を出したら完了」の 1 種類しか表現していない。引数ごとの `finish`（その引数が変わったら完了扱い）は書き方を用意していない
- migration の `label` 変換で、変換後の locals にその時点で存在しない値（新しい param など）をどう埋めるかは、component の params を参照できると仮定して書いた。参照できる範囲は spec 側の決定が要る
