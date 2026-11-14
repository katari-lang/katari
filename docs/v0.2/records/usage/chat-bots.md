---
title: usage 評価 — チャットボットとイベント源
description: spec-base に対して、ターン制・常駐・再接続・受信箱・多種イベント・breaker・スケジュール・人間確認を仮想構文で書き、runtime の挙動と仕様の穴を評価する
---

評価対象は `../2026-09-30-spec-base.md`。各 usage を仮想構文で書き、render / 遷移 / protocol の時系列を追い、
仕様のままで書けるかを判定する。提案は末尾にまとめる。

記法: `→` は Katari→外部、`←` は外部→Katari のメッセージ。address の接頭辞は省略する。

## 1. ターン制の Discord bot

応答中に届いたメッセージは次のターンにまとめる。応答中だけ typing indicator を出す。

```
component Bot(discord: Discord, model: Model) {
  use ch = discord.channel("general")
  state turn: Option<(Int, List<Message>)> = None
  state pending: List<Message> = []

  tool receive(m: Message) = match turn {
    None    => turn <- Some((0, [m]))
    Some(_) => pending <- pending ++ [m]
  }
  discord.watch(ch, on_message = receive)

  when turn is Some((n, batch)) {
    use typing = discord.typing(ch)
    tool finish(r: Result<Unit, Error>) = match pending {
      []  => turn <- None
      ms  => turn <- Some((n + 1, ms)), pending <- []
    }
    Turn(ch, model, batch) key n => finish
  }
}

tool Turn(ch: Channel, model: Model, batch: List<Message>) ~> Unit {
  let answer = await ai.infer(model, prompt(batch))
  await ch.send(answer)
}
```

`finish` は `when` の中で定義し、`n` を捕捉する。`ch.send` は ack を待つので tool（`Text ~> MessageId`）。
fire-and-forget でよい送信は Sink にする。

### 時系列

| 時点 | 出来事 | 遷移 / render | protocol |
|---|---|---|---|
| 0 | mount | `ch`、state、`watch` を宣言 | → init(ch, {name}, cont) / ← init(cont, {send, id}) / → init(watch, {ch, on_message: Sink(receive)}) |
| 1 | m1 到着 | ← send(receive, m1)。`receive`: turn = Some((0,[m1]))。render: `when` が真 | → init(typing, {ch}) / → init(Turn[0], {ch, model, [m1]}, k: Sink(finish)) |
| 2 | Turn[0] 内 | label `answer` で ai.infer を待つ | → init(Turn[0]·answer, …) / ← send(k_answer, text) / → init(Turn[0]·send, …) |
| 3 | m2 到着 | `receive`: pending = [m2]。render: `when` の値は不変 | なし（args 不変なので update も出ない） |
| 4 | Turn[0] 完了 | ← send(finish, Ok(()))。`finish`: turn = Some((1,[m2])), pending = []。render: key 0 → 1 | → dispose(Turn[0]) / ← disposed(Turn[0]) / → init(Turn[1], {ch, model, [m2]}) |
| 5 | Turn[1] 完了、pending 空 | turn = None。`when` が偽 | → dispose(Turn[1]) / → dispose(typing) / ← disposed × 2 |

### 評価

- ターンの遷移は `receive` と `finish` の 2 箇所だけで、v0.1 の desk / turn より短い。直感的
- `typing` の address は turn を跨いでも同じなので、連続ターンの間は消えない。「応答中は表示」としては正しい
- 手順 3 で `pending` が変わっても Turn の args（snapshot）は変わらない。走行中の tool に後から届いたメッセージが混ざらない
- 完了した tool ノードの dispose（手順 4）は外部には何もさせない。protocol 上は dispose → disposed の往復だけ

### 穴

- **失敗の経路が構文に無い。** `Turn` が失敗したとき `=> finish` に何が届くかが決まっていない。spec-base 2.2 は「失敗は第 2 の Sink」とだけ言う。上では `finish` の引数を `Result` にして書いたが、`instant x = T()` の失敗（x が永遠に埋まらない）も同じ問題。提案 P1
- `discord.watch(...)` は bare の子で、label が決まらない（`Child(args)` の Child に当たる名前が method 呼び出し）。提案 P2
- `when` の中で定義した sync tool が外側の State を書けるかは 2.1 の「同じ body」の読み方次第。ここでは書けるものとして扱った。提案 P3

## 2. 複数チャンネル・複数ユーザーの常駐

ユーザーごとに会話 state を持ち、30 日不在なら捨てる。

```
component Residency(discord: Discord, model: Model, channels: List<ChannelSpec>) {
  for spec in channels key spec.id {
    use ch = discord.channel(spec.id)
    use clock = time.clock(resolution = 1.hour)

    state inbox: Map<UserId, List<Message>> = {}
    state seen:  Map<UserId, Timestamp> = {}

    tool receive(m: Message) =
      inbox <- inbox.push(m.author, m),
      seen  <- seen.insert(m.author, m.at)
    tool consumed(user: UserId, id: MessageId) = inbox <- inbox.remove(user, id)
    tool sweep(now: Timestamp) = seen <- seen.filter(\_ t -> now - t < 30.days)

    discord.watch(ch, on_message = receive)
    time.every(clock, 1.day, on_tick = sweep)

    for (user, _) in seen key user {
      Conversation(ch, model, user, messages = inbox[user] ?? [], consumed)
    }
  }
}

component Conversation(ch: Channel, model: Model, user: UserId,
                       messages: List<Message>, consumed: (UserId, MessageId) → Unit) {
  state history: List<Turn> = []
  ...
  for m in messages key m.id {
    Reply(ch, model, history, m) => done          tool done(r) = consumed(user, m.id), history <- ...
  }
}
```

### 時系列（新規ユーザーの最初のメッセージ）

| 時点 | 出来事 |
|---|---|
| 1 | ← send(receive, m)。`receive` が inbox と seen を同時に書く（1 遷移） |
| 2 | render: `for (user, _) in seen` に user が現れ、`Conversation` が init される。`messages` は inbox[user] = [m] |
| 3 | `Conversation` 内の `for m in messages` が Reply を宣言する |
| 4 | Reply 完了 → `done` → `consumed(user, id)` → 親の inbox から消える → 次の render で Reply の宣言が消える |

### 評価

- **外部イベントを動的に生える子へ直接届けることはできない。** 子の Sink を親の callback が知るには子が先に存在している必要があり、
  最初のメッセージで子を作る場合は必ず取りこぼす。親の State に溜めて props（signal）で下ろし、消費を callback で上げる形になる。
  React の props / callback と同じで、書けはするが定型が長い
- 別解: kind が filter を持つ watch を提供し、子が自分の watch を持つ（`discord.watch(ch, author = user, on_message = …)`）。
  外部側で 1 本の接続に多重化できるなら、Katari 側はこちらが短い。kind 設計の指針に入れる。提案 P4
- state の掃除は「`seen` から消える = `for` の要素が消える = Conversation とその state が dispose される」で、機構なし。直感的
- `consumed` と `done` の 2 段（子の sync tool が親の sync tool を呼ぶ）は 1 遷移で commit される（sync tool から sync tool への呼び出しは同期）。
  spec-base 2.4 の「送信は commit 後に配送」との関係を明文化する必要がある。提案 P5

## 3. channel / watch の分離と再接続

### 外部プロセスが落ちて復帰する

Katari から見えるものは、既定では何も無い。watch の JS プロセスが死んでも disposed は来ない（送る主体が居ない）。
復帰した JS は自分が永続化した id で再接続する。落ちていた間のメッセージを拾えるかは kind の責任（Discord の gateway resume など）。

状態を見せたければ kind が export する。

```
use w = discord.watch(ch, on_message = receive)      export status: Connected | Disconnected(since)
when w.status is Disconnected(since) { Alert(ops, ch, since) }
```

外部は `update(cont, { status: Disconnected(…) })` で signal を変える。export が無い watch は `use` できない（`Component(Void)` への use は静的エラー）ので、
同じ kind でも export の有無で書き方が `use w = …` と bare に分かれる。提案 P6

### Katari が落ちて復帰する

再 render で宣言集合を再構成し、SoT の「各 id へ送ったメッセージの連番」から init 済みで dispose していない id の集合が分かる。
両者を比べて差分だけ init / dispose を送る。init 済みの id には何も送らない（外部は自分で復帰している）。
継続の出力（← init(cont, x)）が落ちている間に届いていた場合は、外部が再送し、(id, 連番) で重複除去される。

## 4. 受信箱 Pool + ack と callback の比較

```
// A. callback（親の State に溜める）
tool receive(m) = queue <- queue ++ [m]
discord.watch(ch, on_message = receive)
for m in queue key m.id { Handle(m) => done }        tool done(r) = queue <- queue.remove(m.id)

// B. 受信箱 Pool（kind が ack まで要素を保持する）
use w = discord.inbox(ch)                            export items: Pool<Inbound>   Inbound = { msg, ack: Sink<Unit> }
for m in w.items key m.msg.id { Handle(m.msg) => ack }   tool ack(r) = m.ack <- ()
```

| | A callback | B Pool + ack |
|---|---|---|
| 順序制御・batching | State で自由に書ける | 要素ごと独立。batching は書きにくい |
| 要素の保持 | Katari の State（永続） | 外部（kind の永続化に依存） |
| 失敗時 | `done` で捨てるか残すかを書く | ack しなければ残り続ける。再 render ごとに Handle が再宣言されることはない（address が同じで memo 済み）が、失敗したまま留まる |
| 二重処理 | `receive` が 1 遷移なので無し | ack 前に Katari が再起動しても要素は残るので、Handle の作用は at-least-once |

既定は A。B は「外部のキューを Katari が消費する」という意味が明確なとき（ジョブキュー、Webhook のリトライ付き受信）に使う。
どちらも失敗の扱いを書き手が決める必要があり、P1 が前提になる。

## 5. Slack: スレッド返信・リアクション・編集

イベントの種類は直和にして、callback は 1 つにする。

```
type SlackEvent = Message(m: Message)
                | ThreadReply(parent: Ts, m: Message)
                | Reaction(ts: Ts, emoji: Text, user: UserId)
                | Edited(ts: Ts, text: Text)
                | Deleted(ts: Ts)

use ch = slack.channel("support")
state threads: Map<Ts, Thread> = {}
tool on_event(e: SlackEvent) = match e {
  Message(m)          => threads <- threads.open(m)
  ThreadReply(p, m)   => threads <- threads.append(p, m)
  Reaction(ts, "✅", _) => threads <- threads.close(ts)
  Edited(ts, text)    => threads <- threads.edit(ts, text)
  Deleted(ts)         => threads <- threads.remove(ts)
}
slack.watch(ch, on_event = on_event)

for (ts, t) in threads key ts when t.open {
  ThreadAgent(ch, ts, t) 
}
```

- 1 つの Sink なので種類を跨いだ順序が保たれる（Edited が Message より先に来ない）
- 遷移が全域であることが効く。想定しない組み合わせ（存在しないスレッドへの Reaction）も分岐で無視できる
- 返信は `ch.reply(ts, text)` tool。watch と channel が分かれているので callback から `ch` を捕捉できる（循環なし）

困らない。callback を種類ごとに分ける形（`on_message`, `on_reaction`, …）は順序保証が Sink ごとになるので採らない。

## 6. rate limit / breaker

連続 3 回失敗したら 10 分止め、時間で復帰する。

```
state breaker: Closed(failures: Int) | Open(until: Timestamp) = Closed(0)
use clock = time.clock(resolution = 1.min)

tool outcome(r: Result<Unit, Error>) = match (breaker, r) {
  (Closed(n), Err(_)) => if n + 1 >= 3 then breaker <- Open(clock.now + 10.min) else breaker <- Closed(n + 1)
  (Closed(_), Ok(_))  => breaker <- Closed(0)
  (Open(_), _)        => skip
}
tool reopen(_: Unit) = breaker <- Closed(0)

when breaker is Closed(_) && turn is Some((n, batch)) {
  Turn(ch, model, batch) key n => outcome
}
when breaker is Open(until) {
  time.at(clock, until, on_fire = reopen)
}
```

### 時系列

| 時点 | 出来事 |
|---|---|
| 1 | 3 回目の Err → `outcome`: breaker = Open(t+10m)。render: Turn の宣言が消え（走行中なら dispose）、`time.at` が init される |
| 2 | 10 分後 ← send(reopen, ())。breaker = Closed(0)。render: `time.at` が dispose、Turn が同じ key で再 init（= リトライ） |

### 評価

- sync tool は純粋なので `now()` を呼べない。`clock.now` を signal として snapshot で読む形にした。時刻の供給源を builtin で決める必要がある。提案 P7
- 「Open の間は宣言が消える → 復帰で同じ key で再宣言 → 再実行」がそのままリトライになる。機構が要らない。ただし Turn が走行中に Open になると
  途中で dispose される。「走行中のものは完走させる」にしたければ `when` の条件を `breaker is Closed || running` のように書く。書き手の選択で書ける
- `time.at` は自分の callback で `when` が偽になるので、発火後に dispose される。発火後も `when` が真のままなら inert なノードとして残る。無害

## 7. スケジュール投稿

```
use clock = time.clock(resolution = 1.min)
state due: List<Timestamp> = []
tool tick(t: Timestamp) = due <- due ++ [t]
tool posted(t: Timestamp, r: Result<Unit, Error>) = due <- due.remove(t)
time.cron(clock, "0 9 * * *", on_tick = tick)

when head(due) is Some(t) {
  DailyPost(ch, model, t) key t => posted(t)
}
```

- 実行中に次の tick が来た場合: `due` に積まれ、`head` が変わらないので走行中の Post は影響を受けない。完了後に次が走る（直列）
- 並列でよければ `for t in due key t`。捨てたければ `tool tick(t) = if isEmpty(due) then due <- [t] else skip`。方針は sync tool の 1 行で決まる
- Katari が落ちていた間の tick は、`time.cron` の kind が「復帰時に取りこぼしを送る」かどうかで決まる。Katari 側で保証したければ
  `state last: Timestamp` を持ち、`clock.now` と比べて due を導出する。どちらも書ける
- `=> posted(t)` は sync tool の部分適用。P3 と同じく、`when` の中で `posted` を定義して `t` を捕捉する形でも書ける

困らない。`once` が無くて困る場面もここには無い（宣言 + key で一意性が出る）。

## 8. 人間への確認

bot が人間に質問し、返答を待つ。長時間待ちが State に残る。

```
// A. 質問を resource として持つ
state question: Option<(Int, Text)> = None
when question is Some((n, q)) {
  use ask = human.ask(ch, q) key n                 export answer: Option<Text>, asked_at: Timestamp
  when ask.answer is Some(a) { Continue(a) => resolved }
  time.at(clock, ask.asked_at + 2.days, on_fire = timeout)
}

// B. 質問を tool として持つ
when question is Some((n, q)) {
  Ask(ch, q) key n => answered                     tool Ask(ch, q) ~> Text { await ch.send(q); return await discord.next_reply(ch, from = asker) }
}
```

| | A resource | B tool |
|---|---|---|
| 待っている間の見え方 | `ask` ノードが生きている。admin UI に「開いている質問」として出せる | tool が label `next_reply` で止まっている |
| 取り下げ | `question` を None にすれば dispose。外部は質問を消せる | 同じ |
| 再起動 | 外部が id で復帰。answer が来ていれば update(cont, …) | 葉 `next_reply` が復帰 |
| patch | State（question）だけ。ask に途中状態は無い | label と locals の互換性判定が要る |
| timeout | 同じ枝に `time.at` を置く | tool の中で `par(next_reply, sleep)` |

質問は「寿命を持つもの」なので A が自然。v0.1 の escalation はこの形になる。B は「返答を値として受けて逐次で続ける」書き味が欲しいときに使う。
どちらも仕様のまま書ける。

## 提案

- **P1 (must) 失敗の経路を構文に出す。** `T(args) => k` は `k` に `Result<R, Error>` を渡す。`instant x = T(args)` は `x : Result<R, Error>` で埋まる
  （失敗も「埋まる」）。糖衣として `instant x = T(args) else e`（失敗なら値 e）を用意する。これが無いと usage 1, 4, 6 が書けない
- **P2 (should) bare の子の label。** `discord.watch(...)` のような method 呼び出しの label は最後の名前（`watch`）。同じ body に 2 つあれば `key` 必須
- **P3 (should) 「同じ body」の定義。** `when` / `for` の中で定義した sync tool は、囲む component の State を書ける（for の中なら要素も捕捉できる）。
  これで `=> k` に部分適用（`=> posted(t)`）は要らなくなるが、あってもよい
- **P4 (should) kind 設計の指針: filter 付き watch。** 動的に生える子へ外部イベントを直接届けることはできない（最初のイベントを取りこぼす）ので、
  子が自分で購読できる kind（`discord.watch(ch, author = user, …)`）を推奨する。親の State に溜めて props で下ろす形が代替
- **P5 (should) sync tool から sync tool への呼び出しは同期。** 子の `done` が親の `consumed` を呼ぶとき、両方の書き込みが 1 遷移で commit される
  と明記する。「Sink への送信は commit 後に配送」（2.4）は、外部への送信と async tool への送信についての規則
- **P6 (should) bare と use の統一。** export の無い component は bare でしか書けず、export があると `use` になる。kind に status を export させた
  だけで呼び出し側の構文が変わるのは不便。「`use _ = c` を許す」か「bare で export を捨てる」のどちらかにする
- **P7 (should) 時刻の供給源。** sync tool は純粋なので `now()` を持てない。`time.clock(resolution)` が `now` signal を export する builtin を決め、
  `time.at` / `time.every` / `time.cron` はそれを引数に取る（channel / watch の分離と同型）
- **P8 (nice) render のタイミング。** 遷移ごとに render するのか、連続する遷移をまとめてから render するのかを決める。まとめると `when` が
  真→偽と往復した場合の init / dispose 対が消えるので、観測可能な違いになる。遷移ごと、を既定にする

## 仕様のまま書けたが違和感がある点

- 外部イベント → sync tool → State → `when` → 宣言、という経路は 2 段（遷移と render）で、1 つの外部メッセージに対して原子的。
  遅延は無いが、「callback で直接子を起動できない」ことに慣れが要る（React の setState → 再 render と同じ）
- `=> k` と `instant` の使い分けは「結果で State を変えたいか（=>）、結果を値として下流で使いたいか（instant）」で決まり、迷わない。
  ただし P1 が無いと `instant` は失敗で止まる
- typing indicator（usage 1）のように、address が同じで args も同じ resource は `when` の中身が変わっても残る。意図どおりだが、
  「ターンごとに消して出したい」場合は key に n を入れる必要があり、初見では気づきにくい

## 未決の問い

- 受信箱 Pool（usage 4-B）で ack されない要素の扱い。Katari 側で「N 回失敗したら dead-letter」を書く定型を用意するか、kind に任せるか
- `time.cron` の取りこぼし（Katari が落ちていた間の tick）を kind と Katari のどちらの責任にするか
- 外部プロセスが落ちている間に Katari が dispose を送った場合（配送できない）の扱い。連番付き at-least-once なので復帰後に届く、でよいか
