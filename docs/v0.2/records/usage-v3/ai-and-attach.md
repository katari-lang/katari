---
title: usage 評価 v3 — AI エージェント、tool、動的 attach、capability
description: v3 基底（actor + React + coroutines + terraform）で AI 周りの usage を書き、runtime の挙動と仕様の穴、より妥当な抽象を確かめる
---

対象は `../2026-10-02-spec-base-v3.md`。各節はコード、runtime の挙動、評価の順。提案は末尾に番号付きで集約し、本文では `[P n]` で参照する。

## 1. agent

### コード

```
component Agent(model: Model, goal: Text, tools: Tools) ~> Text {
  state messages: List<Msg> = [system(goal)]
  export state result: Option<Outcome<Text>> = None

  loop {
    let ts   = tools                                       反復の先頭で固定（§評価）
    let step = await ai.infer(model, messages, ts)         label step
    match step {
      Say(t) => { messages <- messages ++ [assistant(t)]; result <- Some(Ok(t)); break }
      Call(calls) => {
        let results = await par(calls.map(c => ts[c.name](c.args)))      label results。反復 key · index
        messages <- messages ++ [assistant(calls)] ++ tool_results(calls, results)
      }
    }
  }
}
```

正典例 D は完了を `out: SendChannel<Text>` で親に送っているが、ここでは `export state result` にした（§1.4）。

### runtime の挙動

```
mount        Agent·messages init。run 開始。label step で ai.infer の葉を init
葉           event(step, Ok(Call([c1, c2])))
run          messages の書き込みと par の開始が同じ sync 区間。commit → render。par の 2 つの sub-call を init（address: Agent·results·0, ·1）
             c2 が human.ask を含む tool なら、その葉が UI に質問を出し、par はそこで止まる（数日）
葉           c1 の結果が先に届く。par はまだ戻らない。c1 の結果は run の locals（par の途中状態）に保存される
runtime 再起動   state と run の位置（label results、c1 の結果済み）を復元。c2 の葉は id で復帰し質問を保持
葉           c2 の結果。par が揃い、messages を書く。次の反復へ
```

`tools` props が会話の途中で変わったとき: run の中の `tools` は読んだ時点の値なので、次の反復の `let ts = tools` から新しい集合になる。
走行中の `ai.infer` と `par` には影響しない。

Agent の宣言が消えたとき（親が取り下げ）: run が cancel され、await 中の葉（human.ask を含む）に dispose が届く。UI から質問が消える。

### 評価

- **`tools` を反復の先頭で `let` に写さないと、`ai.infer` が返した call の名前が dispatch 時の `tools` に無いことがある。** 「読んだ時点の値」の規則は正しいが、1 反復の中で 2 回読む props は固定する、という書き方を読者が知っている必要がある。指針に入れる
- `calls.map(c => ts[c.name](c.args))` は lambda。v3 は fn を top-level としか言っていないが、純粋な式の中の lambda（await を含まず、locals / state / channel に保存しない）は defunctionalize できるので許してよい `[P 7]`。無いと `par` に渡す list を作れない
- `par(list)` の動的個数形が §3.1 に無い（`par(T(a), U(b))` の固定長だけ）`[P 8]`
- 人間を数日待つ tool が `par` に 1 つあると、agent の loop 全体がそこで止まる。新しいユーザー入力を受けられない。これは単一 loop の帰結で、応答性が要るなら「質問を待つ」を子 component に出す。指針 `[P 12]`
- **run が `break` した後、`goal` が変わっても再開しない。** run は宣言につき 1 回で、props の変化で再実行されない。新しい goal は `use a = Agent(…) key goal` で別 instance にする。§3.1 に明記が要る `[P 4]`
- **`ai.infer` が Fault を返して run が捕まえなかったとき、何が起きるかが v3 に無い。** run は終わり、component は宣言されたまま残る。親はそれを知る手段が無い `[P 1]`

### 1.4 完了を親に知らせる経路

| 経路 | 親の受け方 | 向く場面 |
|---|---|---|
| `export state result` | 宣言で `when a.result is Some(…)`、run で `await a.result` | 1 回の結果。構造にも逐次にも使える |
| `out: SendChannel<Text>` | 親の loop が `await results.receive()` | 繰り返す通知、複数の子からの fan-in |

`await a.result`（signal を待つ）があるので、1 回の結果に channel は要らない。指針として「結果は export state、繰り返す通知は channel」`[P 10]`。

## 2. tool 作者の体験

```
tool Search(kb: Knowledge, q: Text) ~> List<Doc> {
  return await kb.query(q, limit = 5)
}

tool Refund(payments: Payments, approver: Human, order: OrderId, amount: Int) ~> Result<Receipt, Text> {
  let ok = await approver.ask(confirm_text(order, amount), options = [Yes, No])
  if ok == No { return Err("declined") }
  return Ok(await payments.refund(order, amount))
}

tool Now(clock: Clock) ~> Text = clock.now                 signal の export を読む。読んだ時点の値

tools = { search = Search(kb, _), refund = Refund(payments, approver, _, _), now = Now(clock) }
```

- 部分適用 `Search(kb, _)` は `Tool<{ q: Text }, List<Doc>>`。schema は残りの params と結果型から出る。tool 値の型が残りの params の **名前** を持つ必要がある（未決）
- 即答の tool は await の無い tool。`fn` を Tools に直接入れる糖衣があってもよい `[P 9]`
- `await approver.ask` は tool の中で数日止まる。cancel は宣言の cascade。runtime 再起動は葉が id で復帰する。v0.1 の parked escalation 問題は無い
- **state を書く tool は無い**（§9 で確認）。tool は引数の handle と channel にしか作用できない

## 3. multi-agent

### ユーザーごと（正典例 B）

```
component Conversation(u: UserId, inbox: ReceiveChannel<Message>, ch: Channel, models: Models, store: Store) {
  use ws    = store.workspace("assistant/" ++ u)             per-AI の記憶
  use model = models.for_user(u)                              per-AI の provider / credential
  state history: List<Turn> = []
  loop {
    let batch  = await inbox.receive_all()
    let answer = await Agent1(model, persona(u), { remember = ws.put, recall = ws.get }, batch)
    await ch.send_as(u, answer)
    history <- history ++ [(batch, answer)]
  }
}
```

v0.1 の spawn の workspace / persona / per-AI provider は、子 component の `use` と引数に全部落ちる。spawn の特別な引数は要らない。

### orchestrator

```
component Orchestrator(model: Model, goal: Text, tools: Tools) {
  state tasks: List<Task> = []
  state done:  Map<TaskId, Text> = {}
  use results = channel<(TaskId, Text)>()

  loop {
    let plan = await ai.infer_json(model, planning_prompt(goal), schema = List<Task>)
    tasks <- plan
    for i in 0 .. length(plan) { let (id, r) = await results.receive(); done <- done.insert(id, r) }
    …
  }
  for t in tasks key t.id { use worker = Worker(model, t, tools, results.send) }
}
```

- 子を動的に生やすのは「loop が state を書く → `for` が宣言する」の 1 本道。子の結果は channel で fan-in する。自然
- `for i in 0 .. n { await results.receive() }` の間、loop は他のことをできない。orchestrator が同時に外部からの指示も受けたければ `race(results.receive(), commands.receive())` で書ける（Kotlin の select 相当）

### 対等な agent

```
component Team(models: Models) {
  use mail = channels<Name, Note>()
  use analyst = Analyst(models, mail.for("analyst"), mail.send)
  use critic  = Critic(models,  mail.for("critic"),  mail.send)
}
```

- 互いの handle は要らない。共有の channel map を親が配るだけ。**Pool / member はここでは不要**
- Pool / member が要るのは「`for` の中で `use` した handle を親が集める」場面（Team handle の収集）だけになった。`for` の出力を map として受ける糖衣があれば Pool は要らなくなる `[P 11]`

## 4. 記憶

```
use ws = store.workspace(name)        export get / put / list（suspend 関数）、watch(key)（signal）
loop { …; await ws.put("notes", notes); … }
```

| | state | store |
|---|---|---|
| 書き手 | 自分の run | handle を持つ誰でも（tool からも） |
| 読み手 | 宣言と run | run と tool（`await ws.get`）、宣言（`ws.watch(key)` の signal） |
| 版を跨ぐ | keep / migrate / reset | 生存集合 |

住み分けは明確。困らない。

## 5. streaming

```
loop {
  let batch = await msgs.receive_all()
  with s = ai.stream(model, prompt(batch)) {          export chunks: ReceiveChannel<Text>
    draft <- ""
    for await c in s.chunks { draft <- draft ++ c }   channel が閉じるまで
  }
  await ch.send(draft)
}
```

- run の中で `with` で stream を開き、閉じるまで受ける。断片ごとに state を書き、await 境界で commit → render。UI は `draft` を描く
- **channel の close と、閉じるまでの反復が v3 に無い。** `receive` が閉じた channel で何を返すか、`for await x in ch` の形 `[P 2]`
- 頻度は runtime の問題。1 断片 = 1 遷移

## 6. MCP

```
use srv    = mcp.serve(listen, tools = { search = Search(kb, _), now = Now(clock) })
use remote = mcp.client(url, auth = oauth.token(cred))        export tools: Tools（接続後に揃う signal）
use a      = Agent(model, goal, local_tools ∪ remote.tools)
```

- serve は run の無い component で tool 値を公開するだけ。**外部が Katari の tool 値を呼ぶとき、誰がその body を走らせるか** が v3 に無い。runtime が serve ノードの scope で run を起こし、address は `srv·(call, id)`、serve の dispose で走行中の呼び出しも cascade、と決める `[P 6]`
- client の `tools` は signal。Agent の props として渡せば、反復ごとに読み直される。tool 集合が変わっても走行中の step は影響を受けない

## 7. 動的 attach

```
component Plastic(spec: Text, env: Env, model: Model, ops: Human, args: I) {
  state cur: Option<(Text, Text)> = None                 (src, migration)
  when cur is Some((src, m)) { use d = link(src, env, I, migration = m) ; use app = d(args) }

  loop {
    let current = if cur is None then None else Some(await d)       宣言の出力を run で読む
    var errors = []
    let proposal = loop {
      let (src', m') = await ai.infer_json(model, prompt(spec, describe(I), current.map(reflect), errors), schema = (Text, Text))
      match await validate(src', env, I)                         { Err(es) => { errors = es; continue }, Ok(()) => {} }
      match current { Some(d) => match await validate_migration(d, src', m') { Err(es) => { errors = es; continue }, Ok(()) => {} }, None => {} }
      let diff = match current { Some(d) => await plan(d, src', m'), None => empty_diff }
      if nonempty(diff.blocked) { errors = blocked_as_errors(diff); continue }
      break (src', m', diff)
    }
    if await ops.ask("apply?", proposal.diff) == Approve { cur <- Some((proposal.src, proposal.m)) }
    await spec_changed                                            次の案は spec の変化を待つ（signal を待つ）
  }
}
```

- 閉ループが 1 本の逐次コードになり、状態機械版より短い。人間の承認は `await ops.ask`
- `cur` を書くと `link` の args が変わり、配下が新しい定義で reconcile される。AI が label を変えれば `plan` の Diff に reset が出て、`blocked` でなければ人間が見て判断する
- **run の中で宣言の出力（`d`）を読む規則が v3 に無い。** `await d` で「宣言されて揃うまで待つ」と定めれば書ける `[P 3]`
- `await spec_changed` のような「signal の変化を待つ」は、`await sig` が「定義 / 真になるまで」だけだと書けない。`await changed(sig)` か、spec を channel にする。未決

## 8. capability

- `ops`、`model`、`env` は `Plastic` の params。生成コードが触れるのは `args: I` の中だけ。`describe(I)` に無い handle は AI の視界に入らない
- `mail.send`（SendChannel）を渡された者だけが送れる。channel の send 側が capability であることは確認できた
- **ReceiveChannel を 2 つの component に渡すと message が分割される**（Kotlin と同じ）。意図しない共有を型か lint で止めたい `[P 5]`
- tool 値 `Reply(ch, persona, _)` を AI に渡しても、AI は Data の引数で call できるだけで `ch` を取り出せない

## 9. tool の等級が無いこと

- state を書く tool は存在しない。tool が component に影響するのは channel への send だけ（§2 の `remember = ws.put` は外部 store への作用）
- AI の tool call で component の挙動を変えたい（「モードを切り替えて」）: `tool SetMode(cmds: SendChannel<Cmd>, mode: Mode) ~> Unit = await cmds.send(SetMode(mode))` を渡し、所有者の loop が `cmds` を受けて state を書く。**所有者の loop が `ai.infer` を await している間は受けられない** ので、agent を子に出して親の loop を空けておく構成になる `[P 12]`
- per-AI の provider 差し替え（v0.1 の handler 注入）は `use model = models.for_user(u)` の handle 注入で足りる。fake は同じ export を持つ component

## 提案

1. **must** run の終了と失敗を可視化する。全 component に暗黙の export `status: Running | Done | Faulted(Fault)`。捕まえなかった Fault は run を終え、component は宣言されたまま `Faulted`。親は `when` か `await` で見る（supervision as data）
2. **must** channel の close。`close()`、閉じた後の `receive` の結果（`Outcome` か終端値）、`for await x in ch { … }`。stream が終われない
3. **must** run の中で宣言の出力（`use` の x、`for` の束縛は不可）を signal として読める。`await x` は宣言されて揃うまで待つ
4. **should** run は宣言につき 1 回。`break` / 完走の後は props が変わっても再開しない。再実行は `key` で別 instance。§3.1 に明記
5. **should** ReceiveChannel は単一消費者。2 か所に渡すと分割される。型（線形）か lint
6. **should** 外部が Katari の tool 値を呼ぶ規則。runtime が handle を宣言したノードの scope で run を起こす。address `srv·(call, id)`。dispose で cascade
7. **should** lambda は純粋な式の中だけ（await を含まず、locals / state / channel に保存しない）。`par(calls.map(…))` のため
8. **should** `par(list)` と `for await` の動的個数形
9. **nice** Tools に `fn` を直接入れられる（即答 tool）
10. **nice** 指針: 1 回の結果は `export state`（親は `await` か `when`）、繰り返す通知は channel。正典例 D の `out` channel は不要
11. **nice** `for` の出力を map で受ける糖衣。あれば Pool / member の出番が無くなる
12. **should** 指針: loop が await で塞がっている間は channel を受けられない。command を受けながら長い処理をするなら、長い処理を子 component に出す。`race(a.receive(), b.receive())` が select 相当

## 仕様のまま書けたが違和感がある点

- 1 反復で 2 回読む props は `let` で固定しないと、間で値が変わる。規則は正しいが、読者が知らないと踏む
- 人間待ちの tool が `par` にあると agent 全体が止まる。単一 loop の帰結で、構造で分けるしかない
- 完了の通知が channel と export state の 2 通り。指針で片付くが、初見では迷う
- Pool / member の出番が「`for` の中の handle の収集」だけになった。channel が通信を全部引き受けたため
- `await d` のように宣言の出力を run で読むのが自然に出てくるのに、v3 に規則が無い

## 未決の問い

- run が終わった component の意味。inert として残すのか、`status` を見て親が消すのが普通か
- channel の buffer 上限と backpressure（`send` の suspend）が永続化と再起動にどう関係するか
- tool 値の型表現。schema 導出に残り params の名前が要る（`Tool<{ q: Text }, List<Doc>>`）
- 「signal の変化を待つ」（`await changed(sig)`）が要るか。`await sig`（定義 / 真まで）だけでは spec の変化を待てない
