---
title: usage 評価 v3 — チャットボット、event 源、channel
description: v3 基底（actor + React + Kotlin coroutines + terraform）に対して、ターン制・並列・再接続・多種 event・breaker・スケジュール・人間確認・channel の第一級性・run 内の読み取り規則・run 1 つの制約を書いて評価する
---

対象は `../2026-10-02-spec-base-v3.md`。各 usage を v3 の仮想構文で書き、runtime の挙動を時系列で追い、
仕様のままで書けるかを判定する。提案は末尾に集約し、本文では `[P n]` で参照する。

記法: `→` は Katari→外部、`←` は外部→Katari。address の接頭辞は省略する。run の中の宣言（`with`）と
await は run のノードの下に address を持つものとして扱う（`run·typing·3` など。`[P 1]`）。

## 1. ターン制 bot

```
component Bot(discord: Discord, model: Model) {
  use ch   = discord.channel("general")
  use msgs = discord.messages(ch)                  ReceiveChannel<Message>
  state status: Idle | Answering(Int) = Idle

  loop {
    let batch = await msgs.receive_all()
    status <- Answering(length(batch))
    with typing = discord.typing(ch) {
      let answer = await ai.infer_text(model, prompt(batch))
      await ch.send(answer)
    }
    status <- Idle
  }
  when status is Answering(n) { use banner = ui.banner("answering " ++ n) }
}
```

### 時系列

| 時点 | 出来事 | run | commit / render | protocol |
|---|---|---|---|---|
| 0 | mount | `receive_all` で suspend | render: ch, msgs, banner 無し | → init(ch) / ← init(cont_ch, {send,…}) / → init(msgs) / ← init(cont_msgs, {receive…}) |
| 1 | m1 到着 | `batch = [m1]`、`status <- Answering(1)`（未 commit）、`with typing` で suspend | commit → render: banner init | ← event(msgs, m1) / → init(run·typing·0) |
| 2 | typing 揃う | `ai.infer_text` で suspend | | ← init(cont_typing) / → init(run·answer·0, …) |
| 3 | m2 到着 | 変化なし（buffer = [m2]） | | ← event(msgs, m2) |
| 4 | 推論完了 | `ch.send` で suspend | | ← event(run·answer·0, Ok(text)) / → init(run·send·0, …) |
| 5 | 送信完了、block 終了 | `status <- Idle`、`receive_all` が即座に `[m2]` を返す、`status <- Answering(1)`、次の `with` で suspend | commit: status は Idle を経て Answering(1) | → dispose(run·typing·0) / → init(run·typing·1) |

### 評価

- 「応答中に届いたものは次のターンへ」が `receive_all` の意味からそのまま出る。turn 番号も pending も要らない。v0.1 の desk / turn より短い
- typing の寿命が `with` の block で、宣言が消えれば dispose。ターンごとに別の address（`·0`、`·1`）なので、同じ typing が持ち越されることはない
- 時点 5 で `Idle` と `Answering(1)` が同じ sync 区間に書かれる。規則「同じ区間で 2 回書けば後勝ち」により render は Answering(1) だけを見る。
  banner の dispose → init の往復は起きない。ただし **区間の途中に await が入れば**（`status <- Idle` の後に `await receive_all` が suspend する場合）往復が起きる。
  これは意味論どおりで、`status` を `receive_all` の後に書く習慣で避けられる。指針として記録
- run の中で `status <- Answering(1)` の直後に `status` を読んだときの値が未定義。自分の書き込みは区間内で即座に見える、と決める必要がある `[P 2]`
- run は `ch` と `msgs` を参照しているので、両方が揃ってから開始する。この依存規則は spec に無い `[P 3]`

## 2. ユーザーごとの並列

```
component Bot(discord: Discord, model: Model, clock: Clock) {
  use ch      = discord.channel("general")
  use msgs    = discord.messages(ch)
  use ticks   = time.every(clock, 1.day)           ReceiveChannel<Tick>
  use inboxes = channels<UserId, Message>()
  state users: Map<UserId, Timestamp> = {}

  loop {
    match await select(msgs.receive(), ticks.receive()) {
      Left(m)  => { users <- users.insert(m.author, m.at); await inboxes.send(m.author, m) }
      Right(t) => for (u, last) in users { if t - last > 30.days { users <- users.remove(u); await inboxes.drop(u) } }
    }
  }
  for (u, _) in users key u { use conv = Conversation(u, inboxes.for(u), ch, model) }
}
```

### 時系列（掃除と再来）

| 時点 | 出来事 |
|---|---|
| 1 | tick。`users.remove(u)`、`inboxes.drop(u)`（buffer を捨てる）。commit → render: Conversation(u) が消える → cascade で run と `with` の resource が dispose |
| 2 | u から message。`users.insert`、`inboxes.send(u, m)`（key が無ければ作る）。render: Conversation(u) が init され、`inboxes.for(u)` から m を受ける |

### 評価

- **loop が 2 つの channel を待つ必要がある。** 掃除は tick で動くので、message と tick を同じ loop で受けるには `select` が要る。
  Kotlin の `select` と同じく、**負けた側の receive が item を失わない**ことが必要。`race` を channel の receive に使うと、
  cancel された receive が item を消費済みかどうかが決まらない `[P 4]`
- `select` の代わりに `merge(msgs, ticks) : ReceiveChannel<Either<…>>` でも書ける。derived channel は stdlib の component で、
  順序は源ごとに保たれる。`select` より意味が単純（loop は 1 本の receive）`[P 4]`
- `channels<K,T>` に `drop(k)` が要る。無いと、掃除した user の buffer に message が残り、再来時に古い message を Conversation が「答える」`[P 5]`
- 掃除と再来の間に message が届いた場合（時点 1 の tick と時点 2 の message が同じ loop の連続する反復）は、順序が loop で直列化されるので整合する
- 別解: Conversation が自分の inbox を持ち（`use inbox = channel()`、`export send`）、親が `conv.send` に送る。親の run が `for` の iteration の
  export を読む手段が無いので今は書けない。`for` の出力を key 付きの collection として run から読める形があれば、親の `channels` と `drop` の管理が消える `[P 6]`

## 3. 分離、再接続、再起動

```
use ch   = discord.channel("general")      送る側。handle
use msgs = discord.messages(ch)            受ける側。ReceiveChannel
```

- `messages` は外部 resource で、Katari 側に buffer（channel component）を持つ。外部は `event(id, m)` を連番付きで送り、runtime が dedup して buffer に積む
- **外部プロセスが落ちて復帰**: 外部は cursor から購読を張り直し、取りこぼしを送る。連番は新しい接続で振り直されうるので、dedup は
  message id で行う必要がある。これは kind の責任（`messages` の kind が「同じ message id は 1 回」を守る）`[P 7]`
- **Katari が落ちて復帰**: buffer と run の位置（`receive_all` で suspend、または `batch` を locals に持って `ai.infer_text` で suspend）が
  SoT にある。前者は復帰後に buffer を読む。後者は葉の再起動契約（`ai.infer_text` は retry、`ch.send` は kind 次第）に従う。
  同じ batch を 2 回受けることは無い（受けた時点で locals に移っている）
- **run が Fault で終わる場合が未定義。** `ai.infer_text` が `Interrupted` を返し、run が catch しなければ run は終了する。
  その後 component はどうなるか（faulted として残る、親に見える、再起動の手段）が spec に無い `[P 8]`

## 4. 複数種類の event

```
type SlackEvent = Message(m) | ThreadReply(parent, m) | Reaction(ts, emoji, user) | Edited(ts, text) | Deleted(ts)

use events  = slack.events(ch)                      ReceiveChannel<SlackEvent>。1 本
use threads = channels<Ts, SlackEvent>()
state open: Set<Ts> = {}

loop {
  let e = await events.receive()
  match e {
    Message(m)            => { open <- open ∪ {m.ts}; await threads.send(m.ts, e) }
    ThreadReply(p, _)     => await threads.send(p, e)
    Reaction(ts, "✅", _)  => { open <- open − {ts}; await threads.drop(ts) }
    Edited(ts, _) | Deleted(ts) => await threads.send(ts, e)
  }
}
for ts in open key ts { use t = ThreadAgent(ch, ts, threads.for(ts), model) }
```

- 1 本の channel なので種類を跨いだ順序が保たれる（Edited が Message より先に来ない）
- 親の loop が全 event の直列化点になる。v0.1 の desk と同じ位置で、ここが詰まれば全 thread が待つ。thread ごとの処理は子に逃がしているので、
  親の loop は配るだけ。十分短い
- 存在しない thread への Reaction は `open` に無いので `drop` が no-op。全域性の問題は無い（loop は普通の逐次コード）

## 5. rate limit / breaker

```
loop {
  let batch = await msgs.receive_all()
  match await try ai.infer_text(model, prompt(batch)) {
    Ok(a)    => { failures = 0; await ch.send(a) }
    Fault(_) => {
      failures = failures + 1
      if failures >= 3 {
        breaker <- Open(clock.now + 10.min)
        await clock.after(10.min)
        breaker <- Closed; failures = 0
      }
    }
  }
}
when breaker is Open(until) { use notice = ui.banner("paused until " ++ until) }
```

- 「止まっている間は message が buffer に溜まり、復帰後にまとめて処理される」が receive_all で自然に出る
- `failures` は run の locals（`var`）で、state にする必要が無い。render に見せたいものだけ state にする。使い分けが明確
- `clock.now` を run の中で読む（signal の現在値）。tool の引数なら call 時の値。整合している

## 6. スケジュール投稿

```
use ticks = time.every(clock, 1.day, at = "09:00")       ReceiveChannel<Tick>。Tick = { scheduled: Timestamp }
loop {
  let t = await ticks.receive()
  await DailyPost(ch, model, t.scheduled)
}
```

- 実行中に次の tick が来れば buffer に積まれ、完了後に順に処理される（直列）。飛ばしたければ `receive_all` して最後だけ使う。並列にしたければ
  tick を state に積んで `for` で子を生やす。方針が loop の 1 行で決まる
- Katari 停止中の tick: buffer は Katari が持つので、停止中は外部が `event` を送れない。復帰時に取りこぼしを送るかは kind の責任。
  `Tick` に `scheduled` を含めておけば、loop 側で「今より古い tick」を判定できる。両方の手段がある

## 7. 人間への確認

```
run {
  match await race(human.ask(req, options = [Approve, Reject]), clock.after(3.days)) {
    Left(Approve) => { decision <- Approved; await exec.run(req) }
    Left(Reject)  => decision <- Rejected
    Right(_)      => decision <- TimedOut
  }
}
```

- `human.ask` は外部 tool（葉）。`race` の負けは dispose され、UI から質問が消える。timeout で質問が取り下げられる
- 取り下げ: 親が `Request` の宣言を消す → run が cancel → `human.ask` に dispose
- 再起動: run の位置は `race` の await。葉は id で質問を保持しており、`on_restart` は「同じ id なら既存の質問に再接続」。
  これは kind の冪等性（同じ id への再 init = 再取得）で、spec どおり
- `race` の両辺は tool（1 回で終わる）なので、channel の `select` の問題（item の消失）は起きない。`race` は tool 用、`select` は channel 用、と分けるのが安全 `[P 4]`

## 8. channel が第一級であることの問題

### 寿命を越える message

```
component Parent() {
  use results = channel<Done>()
  state jobs: Set<JobId> = {…}
  loop { let d = await results.receive(); … }
  for j in jobs key j { use w = Worker(j, results.send) }
}
```

Worker が完了を `results.send(Done(j))` してから親が `jobs` から j を消すまでの間に、親が j を取り下げた場合、`Done(j)` は buffer に残り、
親の loop は取り下げ済みの job の Done を受ける。これは v0.1 の Sink と同じ「古い結果が届く」。

- 判定: **これは mailbox の意味論として正しい。** message は事実で、送り手の寿命とは無関係に残る。受け手の loop が `jobs` と照合して無視する。
  Sink と違うのは、受け手が 1 本の loop で、照合が逐次コードの 1 行で書けること。規則で捨てる必要は無い。指針として「message には相関 id を入れる」を書く
- 送り手が消えた後の message を runtime が捨てる規則は入れない。入れると「送ってから消えた」と「消えてから送った」の区別が要り、channel の意味が複雑になる

### 背圧

- run からの `send` は buffer が一杯なら suspend する（Kotlin と同じ）。外部の event 源は suspend できないので、外部が供給する channel は
  容量の扱いを決める必要がある: unbounded（既定、plan に buffer 長を出す）か、kind が drop 方針を宣言する `[P 9]`

### receive 側を 2 箇所で受ける

- 同じ `ReceiveChannel` を 2 つの run が receive すると、各 item はどちらか一方に届く（competing consumers）。順序は transition の直列化で決まる。
  broadcast が欲しければ別の抽象（`broadcast<T>()`）。Kotlin と同じ区別で、spec に一言要る `[P 9]`

## 9. props / state を run の中で読む

```
component Conversation(u, inbox, ch, model: Model) {
  loop {
    let batch = await inbox.receive_all()
    let a = await ai.infer_text(model, prompt(batch))        ここで model を読む
    await ch.send(a)
  }
}
```

- 親が `model` を変えると、次に読んだ時点から新しい model になる。走行中の `ai.infer_text` は call 時の値で完走する。これは意図どおり（「変えたら変わる」）
- 問題になる例: 1 反復の中で同じ prop を await を跨いで 2 回読む

```
let a = render(model, batch)          古い model
await ch.send(a)
let b = cost(model)                   新しい model。a と b が別の model に基づく
```

  指針「反復の先頭で `let m = model` に写す」で足りる。言語で強制する手段（反復単位の snapshot）は、長い loop で追従させたい場合と衝突するので入れない
- `with r = kind(args)` の args は run の中なので「読んだ時点の値」。block が長くても update は届かない。`with inbox = discord.inbox(ch)` のように
  loop の外側で長く使う resource は、body の `use` にする（signal として追従する）。使い分けを spec に書く `[P 10]`
- state を run で読む場合も同じ。自分しか書かないので、await を跨がなければ値は変わらない

## 10. run は 1 つ

2 つの独立した loop が欲しい例: message に答える loop と、1 日 1 回 digest を投稿する loop。

```
// A. 子 component に分ける
component Bot(...) {
  use ch = …; use msgs = …
  state history: List<Turn> = []
  loop { … history <- … }
  use digest = Digest(ch, model, history, clock)         history は props（signal）
}
component Digest(ch, model, history, clock) {
  use ticks = time.every(clock, 1.day)
  loop { let _ = await ticks.receive(); await ch.send(summarize(model, history)) }
}

// B. 1 つの loop で select する
loop {
  match await select(msgs.receive(), ticks.receive()) { … }
}
```

- 独立していれば A が自然。state を共有するなら、親が持って props で下ろす（読み）か、子が親の channel に送る（書き）。
  後者は親の loop が select で複数の源を受けることになるので、結局 `select` か `merge` が要る `[P 4]`
- 複数の `run` を 1 つの component に許す案は、単一書き手を壊す。採らない。A と B で足りる

## 提案

1. **must** run の中の `with` と await の address を定める: `run · label · 反復番号`。葉の冪等キーに直結する
2. **must** run の中で自分が書いた state は、同じ区間で即座に読める（commit は await 境界、可視性は即時）
3. **should** run は、参照する use の出力が全て揃ってから開始する（宣言と同じ依存規則）
4. **must** channel の多重受信: `select`（負けた receive は item を失わない）か `merge`（derived channel）を stdlib に置く。`race` は tool 用で、channel の receive には使わない
5. **should** `channels<K,T>` に `drop(k)`。無いと掃除した key の buffer が再来時に古い message を渡す
6. **should** `for` の iteration の export を key 付き collection として run から読める形。子が自分の inbox を持ち、親が `conv.send` に送る書き方ができる
7. **nice** 外部 event 源の dedup は message id で行う（連番は接続ごと）と kind 設計の指針に書く
8. **must** run が Fault で終わったときの意味を定める: component は faulted として残り、plan / trace に出る。親は宣言し直す（key 変更）か、kind の `on_restart` で防ぐ。uncaught を黙って止めない
9. **should** channel の容量と overflow 方針（外部供給は unbounded 既定、plan に buffer 長）、competing consumers と broadcast の区別を spec に書く
10. **should** `with` の args は読んだ時点の値で update しない。長く使う resource は body の `use` にする、と使い分けを書く

## 仕様のまま書けたが違和感がある点

- `status <- Idle` の直後に await が入ると banner の dispose → init が往復する。意味論どおりだが、書き方の習慣に依存する
- 親の loop が全 event の直列化点になる。短く保てば問題ないが、v0.1 の desk と同じ注意が要る
- 寿命を越えて残る message（§8）を受け手が照合して無視する、という責任が loop に乗る。Sink の規則で捨てていたものを逐次コードで扱う形

## 未決の問い

- `select` と `merge` のどちらを primitive にするか（merge は `select` で書けるが、`select` の意味論は Kotlin 同様に細かい）
- 外部供給 channel の unbounded buffer を plan でどう警告するか
- run の Fault を親に伝える標準の形（faulted signal を export するか、親の channel に送るか）
