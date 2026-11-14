---
title: usage 評価 v3 — ワークフロー、人間の関与、決済、run の patch
description: v3 基底（actor + React + coroutines + terraform）で承認・パイプライン・retry・fan-in・決済・patch・定期ジョブ・キャンセル・監査ログ・単一書き手の限界を書き、runtime の挙動と仕様の穴を確かめる
---

対象は `../2026-10-02-spec-base-v3.md`。各 usage を v3 の構文で書き、render / run の commit / protocol / 永続化の時系列を追い、
仕様のままで書けるかを判定する。提案は末尾に番号付きで集約し、本文では `[P n]` で参照する。

記法: `→` は Katari→外部、`←` は外部→Katari。run の中の await 位置は `label` で呼ぶ。address の接頭辞は省略する。

## 1. 承認フロー

```
component Request(req: Req, human: Human, exec: Executor, clock: Clock) {
  state decision: Pending | Approved | Rejected | TimedOut = Pending
  run {
    let d = await race(human.ask(req, options = [Approve, Reject]), clock.after(3.days))     label d
    match d {
      Left(Approve) => { decision <- Approved; await exec.run(req) }                         label exec
      Left(Reject)  => decision <- Rejected
      Right(_)      => decision <- TimedOut
    }
  }
}
```

### 時系列

| 時点 | 出来事 | run の位置 / state | protocol |
|---|---|---|---|
| 0 | 親が `Request(r)` を宣言。render（Pending）。run 開始 | `d` で待つ | → init(d·ask) / → init(d·after) |
| 1 | 2 日後に人間が承認 | race が Left で解決。負けた `after` を dispose | ← event(d·ask, Ok(Approve)) / → dispose(d·after) / ← disposed |
| 2 | `decision <- Approved` は次の await で commit | `exec` で待つ。render: Approved | → init(exec) |
| 3 | exec 完了 | run 完了（位置 `end`） | ← event(exec, Ok(…)) |

取り下げは親が宣言を消すこと。run は `d` で cancel され、`ask` と `after` に dispose が届き、human 側は UI から質問を消す。
再起動が時点 0〜1 の間に起きた場合、SoT の run 位置 `d` と送信ログから、`ask` と `after` は init 済みなので再送されず、
human kind が id で質問を復元する。

### 評価

- state は表示のためだけで、流れは run に一本道で書けている。第 2 版の `on` 4 節より短い
- **`race` の負けた側の dispose を待つか。** 構造化並行性に従えば、race は負けた側の ↑ を待ってから戻る。
  負けた側が `interruptible: false` なら race がその完了まで止まる。これは仕様に無い。`[P 1]`
- **await に名前が無い位置の address。** `await exec.run(req)` には `let` が無く、label が決まらない。
  address は冪等キーなので、位置依存の自動採番は patch で壊れる。`[P 2]`
- **run が Fault で終わったとき。** `human.ask` が `on_restart: interrupt` で `Fault(Interrupted)` を返すと、
  `await` が Fault を伝播し、run は catch 無しで終わる。state は Pending のまま、run は死んでいる。
  親からは子の run が死んだことが見えない（export した state は Pending）。`[P 3]`

## 2. 実装 → PR → レビュー → マージ → デプロイ

PR は「レビュー中」という state の間だけ存在する resource。run の `with` ではなく body の `when` で宣言し、run はそれを待つ。

```
component Feature(spec: Spec, gh: GitHub, model: Model, deploy: Deployer) {
  use branch = gh.branch(spec.repo, name = spec.slug)                 component と同じ寿命
  state phase: Implementing | Reviewing | Merged | Deployed = Implementing
  when phase is Reviewing { use pr = gh.pr(branch, title = spec.title) }     寿命 = Reviewing の間

  run {
    var feedback: List<Change> = []
    loop {
      await Implement(model, spec, feedback, branch)                 label impl
      phase <- Reviewing
      let p = await pr                                                label pr    宣言が揃うまで待つ
      match await Review(model, p) {                                  label review
        Approve    => { await p.merged; phase <- Merged; break }      label merged   signal を待つ
        Changes(c) => feedback = feedback ++ [c]
      }
    }
    await deploy.run(branch.sha)                                      label deploy
    phase <- Deployed
  }
}
```

### 時系列（差し戻し 1 回）

| 時点 | 出来事 |
|---|---|
| 0 | render（Implementing）。`branch` init。run が `impl` で待つ |
| 1 | impl 完了。`phase <- Reviewing`。次の await（`pr`）で commit → render → `when` が真 → `pr` init |
| 2 | `pr` が揃う。run が `review` へ |
| 3 | Changes。feedback に積む。loop 先頭。`impl` を再び await（同じ label、反復 2）。`phase` は Reviewing のまま → PR は残る |
| 4 | impl 完了。`phase <- Reviewing`（変化なし）。`await pr` は即時。review → Approve。`merged` を待つ |
| 5 | 人間が merge → `pr.merged` が真 → `phase <- Merged` → `when` が偽 → `pr` dispose（kind の dispose は「Katari の関与をやめる」であり PR を閉じない） |
| 6 | deploy → Deployed → run 完了 |

### 評価

- **寿命は body、順序は run** という分担がそのまま出ている。PR が「Reviewing の間だけ」という事実が `when` に書かれ、run は順序だけを書く
- **run から条件付き宣言を読む規則が要る。** `let p = await pr` の `pr` は `when` の下にある。run から見た型は `Option<Pr>`（`when`）や
  `Map<Key, X>`（`for`）で、`await pr` は Some になるまで待つ、と定める必要がある。`[P 4]`
- `with` を使うのは「run のある区間だけ要る resource」（一時ファイル、typing indicator）。state に紐づく寿命は `when`。使い分けは説明できる
- dispose が「削除」か「関与をやめる」かは kind の宣言。branch は削除、PR は放置、が自然。plan に「dispose で外部に何が起きるか」を出す。`[P 5]`
- loop の 2 周目で `impl` の address は `impl · 2`（反復 key）。1 周目の結果と別の id になるので、葉が「再取得」と誤認しない

## 3. retry / backoff / timeout

```
component Fetch(url: Text, http: Http, clock: Clock, ctl: ReceiveChannel<Ctl>) {
  export state attempt: Int = 0
  export state result: Pending | Done(Body) | GaveUp = Pending
  loop {
    match await try race(http.get(url), clock.after(10.s), ctl.receive()) {        label got
      Left(Ok(b))      => { result <- Done(b); break }
      Right(RetryNow)  => attempt <- 0
      _                => {
        attempt <- attempt + 1
        if attempt > 5 { result <- GaveUp; break }
        await race(clock.after(backoff(attempt)), ctl.receive())                    label wait
      }
    }
  }
}
```

### 評価

- 途中状態（attempt）は export した state で外から見える。外から変える（今すぐ retry）は、長い await を制御用 channel と race する。
  **run は await している葉からしか起こされない** ので、外からの操作は必ず channel を race に混ぜる形になる。3 本以上を race で混ぜる
  のは読みにくく、Kotlin の `select` 相当が欲しい。`[P 6]`
- props の変化（url が変わった）は、run が `url` を次に読むまで反映されない。`http.get(url)` を待っている最中に url が変われば、
  古い url の結果を Done にする。追従させたいなら `race(http.get(url), changed(url))` のように「signal の変化」を待つ必要がある。
  `await sig` は「定義される / 真になる」だけで、「変わる」を待てない。`[P 7]`
- 一時停止は親が `when not paused { use f = Fetch(…) }` と書けば、run と state ごと消える。attempt を保持したければ親の state に出す。
  宣言の消滅 = cancel が一貫していて読みやすい

## 4. fan-out / fan-in

```
// A. run の中で par
run {
  let rs = await par(items.map(i => Process(model, i)))          label rs
  summary <- Some(await Summarize(model, rs))                     label sum
}

// B. 子 component と channel
use results = channel<(Id, R)>()
for i in items key i.id { use p = Processor(model, i, results.send) }
state done: Map<Id, R> = {}
loop {
  let (id, r) = await results.receive()
  done <- done.insert(id, r)
}
when size(done) == length(items) { use s = Summarizer(model, values(done)) }
```

| | A | B |
|---|---|---|
| 記述量 | 2 行 | 6 行 |
| 途中経過 | rs が揃うまで不透明。葉はノードとして見える | 各 Processor が address を持つ。done が signal |
| items の変化 | run は開始時の items で走る。追従しない | 追加分だけ init。既存は keep |
| 1 件の失敗 | Fault が par 全体に伝播 | その item だけ結果が無い |
| 古い結果 | 無い（par の子は run と同じ寿命） | **cancel された子の結果が channel に残りうる**（下） |

- `par(list)` の各要素の address は位置（`rs · 0`、`rs · 1`）になる。items の順序が変わると id がずれる。要素に key を与える形が要る。`[P 8]`
- B で Processor が結果を send した直後に items から消えた場合、buffer に残った結果を親が受け取る。v0.1 の Sink の「寿命を越えて情報が逃げる」
  がそのまま戻っている。channel は Kotlin の意味論（送ったものは残る）なので仕様としては正しいが、送り手の宣言が消えたら未受信の
  要素を取り下げる `mailbox` の変種があれば、親は id の検査を書かずに済む。`[P 9]`

## 5. 決済（at-most-once）

```
component Checkout(order: Order, pay: Payments, cmds: ReceiveChannel<Cmd>) {
  export state phase: Cart | Paying | Paid(Receipt) | Failed(Fault) = Cart
  run {
    await cmds.receive()                                           label submit
    phase <- Paying
    match await try pay.charge(order) {                             label charge
      Ok(r)    => phase <- Paid(r)
      Fault(f) => phase <- Failed(f)
    }
  }
}
kind pay.charge   replace: forbidden   interruptible: false   on_restart: interrupt
```

| 状況 | 挙動 |
|---|---|
| 再起動（init 送信済み、結果未受信） | run 位置 `charge`、送信ログに init あり。再送しない。葉が id で復元し、`on_restart: interrupt` なら `Fault(Interrupted)` → Failed |
| patch で `charge` label が残る | 続行。葉には何も届かない |
| patch で非互換、migration 無し | run は最初から。`submit` で `cmds.receive()` を待つ。Submit は消費済みなので止まる。二重決済は起きないが run は進まない |
| 親の reset で `phase` が Cart に戻る | run の位置は `charge` のまま → phase = Cart なのに決済中。**state の reset と run の位置が別々に扱われると矛盾する** |

`[P 10]` state の reset と run の位置は 1 つの単位で扱う。片方だけ reset する plan は作らない。

`replace: forbidden` は、走行中の `charge` の宣言が消える patch（run の reset を含む）を plan がブロックする、と読む。
同じ address で `charge` に再び到達した場合（run のやり直し後に Submit が再送された場合）は、同じ id で init が届き、葉が冪等キーで既存の決済を返す。

## 6. 走行中の run に patch が来る

```
tool Onboard … の代わりに、component の run で書く
run {
  await mail.send(welcome(user))                     label welcome
  let answer = await human.ask(manager, q(user))     label answer     数日
  await mail.send(summary(user, answer))             label summary
}
```

| ケース | 走行中の位置 | plan | migration |
|---|---|---|---|
| (a) `answer` の前に `let team = await hr.lookup(user)` を挿入 | `answer {}` | 互換。続行。挿入した `team` は走らない（既に通過した位置）。plan に「in-flight では skip」と出す | 不要。走らせたければ `at answer {} => team {}`（質問を取り下げて出し直す） |
| (b) locals の型変更（answer: Text → Answer） | `summary { answer: Text }` | 非互換 | `at summary { answer } => summary { answer = parse(answer) }` |
| (c) state と run の両方 | 任意 | 両方の互換判定。片方でも非互換なら migration か reset。`[P 10]` の単位 | `component X { state old => …; at l { … } => l { … } }` を 1 つの migration に |
| (d) loop の形が変わる（`loop` → `for attempt in 0..5`） | `got · 3 { … }` | 反復 key の意味が変わる。label が同じでも key の型が違えば非互換 | `at got · n { … } => got · n { … }` の wildcard が要る。`[P 11]` |
| (e) 完了した run | `end` | 新定義の run とは無関係。再実行しない。再実行したければ reset（key 変更） | 不要 |

- 位置の互換判定は「新定義に同じ label があり、locals の型が互換」。これは逐次コードの読者に「どこで止まっているか、何を持っているか」で説明できる
- (a) の「挿入した await は走らない」は意図どおりだが、気付かないと驚く。plan が必ず出すこと
- (e) は、run が完了した component は「構造だけが残る」状態で、再 render されても run は二度と走らない。これは「run は component につき 1 つ、1 回」の帰結で、
  定期的に走らせたいなら loop で書く、が規則になる

## 7. 定期ジョブ

```
component Digest(cal: Calendar, model: Model, ch: Channel) {
  use ticks = cal.ticks(every = 1.day, at = "09:00")              ReceiveChannel<Tick>
  export state history: List<Run> = []
  loop {
    let t = await ticks.receive_latest()                           溜まった tick は捨てて最新だけ
    let r = await try Compose(model, t)
    history <- take(100, history ++ [(t, r)])
  }
}
```

| 方針 | 書き方 |
|---|---|
| 直列（溜める） | `ticks.receive()`。buffer に溜まり、順に処理 |
| 飛ばす | `ticks.receive_latest()` |
| 並列 | tick ごとに子: run が `pending` に積み、`for t in pending key t { use job = Job(t, done.send) }` |

- 方針が receive の 1 行で決まるのはよい
- Katari が止まっていた間の tick は、`cal.ticks` の葉が復帰時に送るかどうかで決まる（kind の責任）。channel の buffer は Katari が持つので、
  Katari が受け取った後の tick は失われない
- `history` が伸びる問題は §9

## 8. キャンセル

親の宣言が消えたとき、§1 の Request で `exec` を待っている場合:

```
1  render で Request の宣言が消える
2  ↓ を依存の逆順に: run の中の with 資源（内側から）→ await 中の葉 exec → state ノード
3  → dispose(exec)。葉が中止して ← disposed
4  run は exec の await で止まったまま終わる。以降のコードは走らない
5  全て ↑ したら接頭辞が消える
```

- `interruptible: false` の葉（決済）を待っている場合、runtime は dispose を送らず完了を待つ。完了の結果は run に届かない（run は cancel 済み）。
  親の ↑ も待つ。plan / trace に `disposing (waiting for pay.charge)`
- **cancel 時の後始末が run の中に書けない。** 「取り下げられた」と人間に伝える、作りかけの下書きを消す、などは cancel された run には書けない。
  第 2 版は「終わりを決めた側が次の枝で宣言する」としたが、親は run の局所（下書きの id）を知らない。
  Kotlin の `finally`（cancel 時にも走る）を借りれば書ける。`[P 12]`

## 9. 履歴・監査ログ

```
loop {
  let e = await events.receive()
  state <- step(state, e)
  await audit.append(address(self), e)               label append
}
```

- 遷移のたびに外部へ追記するのは run の中では自然。state には構造が依存する小さな Data だけを置き、履歴は store。住み分けは説明できる
- 再起動が `append` の init 送信後・位置 commit 前に起きると append が再送される。append の id（`append · n`）を store の kind が冪等キーに
  使えば重複しない。tool の葉は全部この規則で、仕様どおり
- `state <- …` と `await audit.append` の間で commit されるので、「state は進んだが監査ログは無い」瞬間が render から見える。原子性が要るなら
  append を先に await する。順序の問題として書き手が選べる

## 10. 「state の書き手は run だけ」で書けない形

| 場面 | 書き方 | 足りるか |
|---|---|---|
| 子の結果で親の state を変える | 子に親の `SendChannel` を渡し、親の run が受けて書く | 足りる。ただし親の run が受信 loop になる |
| 複数の子からの集約 | 同上。id 付きで受ける | 足りる。§4 の古い結果の問題あり |
| 外部 UI からの操作 | `export cmds.send`。UI は protocol の `event` でその channel に送る | 足りる |
| props の変化に run が反応する | run が次に読むまで反映されない。待っている最中は `changed(prop)` を race する | `[P 7]` が要る |
| 親の run が「配線役」と「自分の仕事」の両方を持つ | 1 本の loop で複数 channel を race する | `select` が無いと読みにくい `[P 6]` |

最後の行が本質で、「run は 1 つ」の制約は「複数の入力を 1 本の loop で多重化する」ことを強いる。Kotlin がそのために `select` を持つのと同じ理由で、
Katari にも要る。子 component に分ければ run は増やせるが、親の state を書くのは親の run だけなので、集約は結局親の 1 本に戻る。

## 提案

1. **should** `race` は負けた側の ↑ を待ってから戻る、と明記する。負けた側が `interruptible: false` なら race がその完了まで止まる。plan / trace に出す
2. **must** run の中の await の label 規則。`let x = await …` は x。`let` の無い await は `callee名 · 出現順` を自動 label にし、plan は自動 label を警告付きで出す。migration の `at` はどちらも参照できる
3. **should** run の終了状態（`Running | Done | Faulted(f) | Cancelled`）を runtime が各 component に自動で signal として持たせ、親が `child.status` で読める。catch されなかった Fault が黙って run を止めない
4. **must** run から body の宣言を読む規則。`when` の下の `use x` は run から `Option<X>`、`for` の下は `Map<Key, X>` として見え、`await x` は Some になるまで suspend する。「寿命は body、順序は run」の分担がこれで成立する
5. **nice** kind の静的宣言に dispose の意味（`on_dispose: delete | detach`）を加え、plan が「dispose で外部に何が起きるか」を出す
6. **must** `select`（複数の suspend を待ち、先に揃った 1 つの枝を実行）。Kotlin から借りる。3 本以上の race と、配線役の loop に必要
7. **should** `await changed(sig)`（signal の値が変わるまで suspend）。`await sig` は定義 / 真を待つだけなので、props の変化に run が反応する手段が無い
8. **should** `par` を list に適用するときの要素の address。`par(items, key = i.id) { Process(model, i) }` の形で key を与える。位置採番は items の順序変化で id がずれる
9. **nice** 送り手の宣言が消えたら未受信の要素を取り下げる channel の変種（`mailbox`）。v0.1 の Sink の問題を既定では持ち込まず、必要な所だけで使う
10. **must** state の reset と run の位置は 1 つの単位で扱う。plan は「state を reset して run は続行」を作らない。migration も `component X { state …; at … }` を 1 塊で書く
11. **should** migration の `at` に反復 key の wildcard（`at got · n { … } => got · n { … }`）。loop の中の位置を 1 行で移せる
12. **should** run に `finally`（cancel 時にも走る。Kotlin から借りる）。cancel された run の後始末（取り下げの通知、下書きの削除）を run の局所情報で書ける。
    ↑ は finally の完了を待つ。finally の中の await は plan / trace に出る。第 2 版の「unmount hook は無い」をこの範囲で緩める

## 仕様のまま書けたが違和感がある点

- 流れが run に一本道で書けるのは明らかに読みやすい。第 2 版で state 機械に散っていた `n` や `step` が消えた
- `state <- v` が次の await まで commit されないので、`decision <- Approved; await exec.run(req)` の順で書くと「Approved が見えてから exec」になる。
  意図どおりだが、await の直前の書き込みが「その await と同時に見える」ことは明記が要る
- run の中の `with` と body の `when … { use … }` の両方で resource を確保できる。使い分け（区間 か state か）は説明できるが、初見では迷う
- `break` で loop を抜けた run は完了し、二度と走らない（§6 (e)）。「component の run は 1 回」の帰結で、常駐は loop で書く、と教える必要がある
- channel の buffer が Katari の永続化対象になるので、SoT に「未消費の event」が加わる。再起動後に古い event を処理することになるが、これは意図どおり（取りこぼさない）

## 未決の問い

- `finally` を入れる場合、cancel 中に finally が長く待つ（人間への通知で返答を待つなど）ことを許すか。↑ が遅れる
- run が Fault で終わった component を親がどう扱うか。`status` を読んで `when` で作り直す（key を変える）形で足りるか、runtime の再試行方針（supervisor）を持つか
- `receive_latest` / `receive_all` のような channel の読み方の語彙をどこまで stdlib に持つか
- 完了した run を持つ component を再び走らせたいとき、key を変える以外の手段を用意するか
