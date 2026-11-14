---
title: usage 評価 — ワークフローと人間の関与
description: 承認・パイプライン・retry・fan-out・決済・patch・定期ジョブ・キャンセルを spec-base の仮想構文で書き、runtime の挙動と仕様の穴を確かめる
---

対象は `2026-09-30-spec-base.md`。各 usage を仮想構文で書き、runtime の挙動を時系列で追い、仕様の穴を提案にまとめる。
提案は末尾に番号付きで集約する。本文中では `[P n]` で参照する。

共通の前提として、ここでは tool の失敗を `Result<R, E>` 型の結果として 1 本の Sink で運ぶ（`[P 2]`）。
`instant r = T(args)` は `r : Result<R, E>` を束縛し、tool body では `await T(args)?` で `Err` を自分の結果に伝播する。

## 1. 承認フロー

申請 → 人間の承認（数日）→ 実行。却下・タイムアウト・取り下げ。

```
component Request(req: Req, human: Human, exec: Executor, clock: Clock) {
  state decision: Pending | Approved | Rejected | TimedOut = Pending

  tool decide(d: Decision) = decision <- match d { Approve => Approved, Reject => Rejected }
  tool expire(_: Unit)     = decision <- TimedOut

  when decision is Pending {
    ask:  human.ask(req, options = [Approve, Reject]) => decide
    ttl:  clock.after(3.days)                          => expire
  }
  when decision is Approved { instant done = exec.run(req) }
}
```

`ask:` / `ttl:` は `=> k` 形の宣言に label を付けるための記法で、spec-base には無い（`[P 1]`）。
取り下げは親が `Request(...)` の宣言を消すことで行い、Request の中には現れない。

### 時系列

| 時点 | 出来事 | protocol | state |
|---|---|---|---|
| 0 | 親が `Request(r)` を宣言 | init(R·ask, {req, options}, k=decide) / init(R·ttl, {3d}, k=expire) | Pending |
| 1 | 3 日以内に人間が承認 | send(decide, Approve) | Approved |
| 2 | 再 render。`when Pending` が偽 | dispose(R·ask) / dispose(R·ttl) | |
| 3 | `when Approved` が真 | init(R·done, {req}, k) | |
| 4 | exec 完了 | send(k, Ok(…)) → done が埋まる | |

取り下げ（親が宣言を消す）は時点 1 の代わりに dispose(R·ask) / dispose(R·ttl) が届き、human 側は UI から質問を取り下げる。
state ノードも消えるので、取り下げ後に承認が届くことはない。

### 評価

- 状態機械として素直に読める。承認待ちが `human.ask` という 1 つのノードとして DAG に見えるのは、v0.1 の escalation と同じ位置づけで直感的
- **時点 1 と ttl の発火が同時に近いとき**、`expire` が `decide` の後に届くと `Approved` を `TimedOut` で上書きする。
  遷移は直列化されるので順序は決まるが、2 つ目の送信は「宣言が消えたノードからの送信」で、これを捨てる規則が spec-base に無い。
  `send(sink, value)` に送信元 id が無いので runtime には判別できない（`[P 3]`）。
  この規則が無いと、sync tool 側で `match decision { Pending => …, _ => 変更なし }` と書いて防ぐ必要があり、全ての遷移がその形になる
- 同じことを tool body で書くなら `let d = await race(human.ask(req, …), clock.after(3.days))` だが、`race` は spec-base に無い（`[P 4]`）。
  承認は途中の状態（待っていること、取り下げ）を外から見て変える必要があるので、component で書く方が合っている（§9）

## 2. 実装 → PR → レビュー → マージ → デプロイ

差し戻しがあるループ。branch / PR は resource（`use`）、推論は `instant`。

```
component Feature(spec: Spec, gh: GitHub, model: Model, deploy: Deployer) {
  use branch = gh.branch(spec.repo, name = spec.slug)
  state feedback: List<Change> = []

  instant impl   = Implement(model, spec, feedback, branch)
  use     pr     = gh.pr(branch, title = spec.title)  after impl
  instant review = Review(model, pr)                  after impl

  tool onReview(r: Result<Verdict, E>) = match r {
    Ok(Changes(c)) => feedback <- feedback ++ [c]
    _              => 変更なし
  }
  review => onReview

  when pr.merged { instant d = deploy.run(pr.sha) }
}
```

`review => onReview` は「埋まった instant の値を sync tool に流す」形で、`instant` と `=> k` を同時に使いたいときに要る（`[P 1]` の一部）。
`pr.merged` は PR resource が export する signal で、GitHub 側の変化は protocol の `update(継続, x')` で届く。

### 時系列（差し戻し 1 回）

| 時点 | 出来事 | 宣言の変化 |
|---|---|---|
| 0 | mount | branch init。impl init（feedback = []）。pr / review は impl 待ちで未宣言 |
| 1 | impl 完了 | pr init（branch, title）。review init（pr は継続で揃う） |
| 2 | review 完了: Changes(c) | onReview → feedback = [c] |
| 3 | 再 render | impl の args が変わったので作り直し（dispose → init）。pr は args 不変・`after impl` の依存先が未完了 → 継続が引っ込む |
| 4 | impl 完了（2 回目） | pr の継続が復活。args 不変なので PR は keep（update も無し）。review は `after impl` の値が変わったので作り直し |
| 5 | review 完了: Approve | 変更なし。人間が merge |
| 6 | `pr.merged` が真 | deploy.run init |

### 評価

- resource と derivation の使い分けは読める。「PR は消さない、推論はやり直す」が `use` / `instant` の違いとして見える
- 時点 3 の「pr の継続が引っ込む」が問題になる。`after impl` を持つ `use pr` は impl が未完了の間、継続（`review`、`when pr.merged`）が存在しない。
  PR ノード自身は生きているので GitHub の PR は残るが、この間に merge されても `when pr.merged` が無い。impl 完了後に復活して拾うので結果は正しいが、
  「resource の継続が一時的に消える」ことを読者が予期するかは疑わしい
- 時点 4 で review が作り直されるのは `after impl` の値が変わったからだが、`Implement` が同じ値（例えば `Unit`）を返すなら作り直されない。
  `after x` は x の**値**ではなく**埋まり直し**に依存すべき（`[P 5]`）
- レビューが人間の場合は `gh.reviews(pr, on_review = onReview)` と watch で受ける形になり、`review` の instant が消えるだけで構造は同じ

## 3. retry / backoff / timeout

component で書く形と tool body で書く形。

```
component Fetch(url: Text, http: Http, clock: Clock) {
  state attempt: Int = 0
  state outcome: Trying | Done(Body) | GaveUp = Trying

  tool got(r: Result<Body, E>) = match (outcome, r) {
    (Trying, Ok(b))  => outcome <- Done(b)
    (Trying, Err(_)) => if attempt >= 5 then outcome <- GaveUp else attempt <- attempt + 1
    _                => 変更なし
  }
  tool timedOut(_: Unit) = got(Err(Timeout))

  when outcome is Trying {
    use delay = clock.after(backoff(attempt))
    req:  http.get(url)   => got       after delay
    ttl:  clock.after(10.s) => timedOut after delay
  }
}
```

`attempt` が変わると `delay` の args が変わり作り直され、`req` / `ttl` は依存先が変わったので作り直される。
key は要らない。timeout で `attempt` が進むと `req` の宣言が消え、http の葉に dispose が届いて中止される。

```
tool fetch(url: Text, http: Http, clock: Clock) ~> Result<Body, E> {
  loop attempt from 0 {
    match await race(http.get(url), clock.after(10.s)) {          label got
      Left(Ok(b))  => return Ok(b)
      _            => if attempt >= 5 then return Err(GaveUp)
                      else await clock.after(backoff(attempt))     label wait
    }
  }
}
State = got { attempt: Int } | wait { attempt: Int }
```

### 評価

- component 形は `when` の枝が「今何が走っているべきか」を表しており、timeout による中止が宣言の消滅として自然に出る
- `got` の遷移が `(outcome, r)` で全域になっているのは `[P 3]` が無いための防御で、`[P 3]` があれば `Trying` の分岐だけでよい
- tool body 形は短いが `race` が要る（`[P 4]`）。`loop` は同じ label を locals を変えて回るだけで、状態の直和は 2 variant で済む
- backoff の遅延中に patch が来ても、`wait { attempt }` の label が残っていれば keep。退避先が読みやすい

## 4. fan-out / fan-in

N 件を並列に処理して集約。

```
tool summarizeAll(items: List<Item>, model: Model) ~> Result<Text, E> {
  let rs = await par(items.map(i => Process(model, i)))?        label rs
  return Ok(await Summarize(model, rs)?)                         label sum
}
State = rs {} | sum { rs: List<R> }
```

```
component SummarizeAll(items: List<Item>, model: Model) {
  pool results: Pool<{ id: Text, r: R }>
  for i in items key i.id {
    instant r = Process(model, i)
    when r is Ok(v) { member results.admit { id: i.id, r: v } }
  }
  when count(results) == length(items) {
    instant summary = Summarize(model, values(results))
  }
}
```

### 比較

| | tool body | component |
|---|---|---|
| 記述量 | 2 行 | 8 行 |
| 途中経過の観測 | 無し（`rs` が揃うまで不透明） | 各 `Process` がノード。plan / trace に見える |
| 入力が変わったとき | 全部やり直し | 追加された item だけ新規。既存の結果は keep |
| 1 件の失敗 | `?` で全体が Err | その item だけ結果が無い。集約条件が真にならない |
| patch | `rs {}` の間は 1 label。互換なら keep | ノードごとに keep |

- component 形は**入力の変化に対して増分**で、tool 形は**一括**。これが使い分けの本質で、記述量の差ではない（§9）
- component 形で `for` の iteration の結果を集めるのに `pool` + `member` が要る。`for` の iteration の export を Pool として受ける形が無いので、
  1 行で済むはずのことに 3 宣言かかる。設計上は member で表せるので仕様の穴ではないが、糖衣の候補（違和感として記録）
- `count(results)` を `when` で読み、`member` は `for i in items` の中にある。読んでいる pool と member の宣言が別の `for` に属するので層化は通る

## 5. 決済（at-most-once）

```
component Checkout(order: Order, pay: Payments) {
  state phase: Cart | Paying | Paid(Receipt) | Failed(E) = Cart

  tool submit(_: Unit)                = phase <- Paying
  tool paid(r: Result<Receipt, E>)    = phase <- match r { Ok(x) => Paid(x), Err(e) => Failed(e) }

  when phase is Paying { charge: pay.charge(order) => paid }
}
```

`pay.charge` の kind 宣言:

```
kind pay.charge     replace: forbidden     interruptible: false     idempotency: address
```

### 二重実行が起きないことの確認

id = address = `Checkout·(…)·charge`。葉は id を冪等キーとして決済 API に渡す。

| 状況 | protocol | 結果 |
|---|---|---|
| 正常 | init(charge, order, k) → send(k, Ok(receipt)) | Paid |
| runtime 再起動（charge 送信済み、結果未受信） | 再 render → 同じ id で init が再送（at-least-once） | 葉は同じキーなので API が既存の決済を返す。二重にならない |
| patch で `phase` が非互換、migration 無し | reset → `phase = Cart` → `when Paying` が偽 → dispose(charge) | kind が `replace: forbidden` なので plan がブロック（下） |

### `when` が反転する危険なケース

```
state paid: Bool = false                          v1
when not paid { charge: pay.charge(order) => k }

state paid: Option<Receipt> = None                v2（型が非互換、migration 無し）
```

reset で `paid = None` になり `when not paid`（v2 では `paid is None`）が真のまま → `charge` が同じ address で再宣言 → dispose → init。
id が同じなので葉の冪等キーは同じで、API は既存の決済を返す。**葉が address を冪等キーにしていれば二重にならない。**
plan は次を出す。

```
! Checkout·(Order,"o-7")·paid      reset (Bool → Option<Receipt>)
-/+ Checkout·(Order,"o-7")·charge   dispose + init (declaration re-enters)   BLOCKED: kind forbids replace
    write a migration for `paid`, or --force-replace
```

反転が危険になるのは、葉が address を冪等キーに使わない場合（`http.post` を直接呼ぶなど）だけで、それは kind の設計の問題として切り分けられる。
決済を `key attempt` で宣言すると address が変わり冪等キーも変わるので、**retry を key で書いてはいけない**。同じ address のまま再宣言し、葉の冪等性に任せる（§9 に指針として記す）。

`interruptible: false` は次を意味する: runtime は dispose を葉の完了まで送らず、完了の送信は port の所有者が生きていれば届ける。
これは `[P 3]`（dispose 済みノードからの送信を捨てる）の例外ではなく、dispose がまだ発行されていないので送信は正当、という整理になる。

## 6. 長時間 tool の途中で patch が来る

```
tool Onboard(user: User, mail: Mail, human: Human) ~> Result<Unit, E> {         v1
  let _      = await mail.send(welcome(user))?                     label sent
  let answer = await human.ask(user.manager, question(user))?      label answer   数日
  let _      = await mail.send(summary(user, answer))?             label done
  return Ok(())
}
State v1 = sent {} | answer {} | done { answer: Answer }
```

v2 は `answer` の前に `let team = await hr.lookup(user)?`（label `team`）を挿入し、質問に team を含める。

```
State v2 = sent {} | team {} | answer { team: Team } | done { team: Team, answer: Answer }
```

走行中の呼び出しが `answer {}` にいるとき:

- v2 の `answer` は `team` を要求するので**非互換**
- migration 無し → reset → `sent` からやり直し → welcome を再送。`mail.send` が `replace: forbidden` なら plan がブロック
- migration の書き方は 2 通り

```
migration {
  tool Onboard {
    at answer {} => team {}                              team から続ける。人間への質問は取り下げて出し直す
  }
}
migration {
  tool Onboard {
    at answer {} => answer { team = Team.unknown }       質問を維持し、team は既定値で埋める
  }
}
```

### 評価

- 「どの label にいるか」と「そこで何を持っているか」が plan に出るので、migration に何を書くべきかは分かる。tool の状態が label ごとの直和になっているのが効いている
- 1 つ目の migration では `human.ask` の宣言が消えるので dispose が届き、質問が取り下げられる。UI 上は同じ人に似た質問が再び来る。これは正しい挙動だが、migration を書く人が気付く必要がある。plan に「この migration で dispose される葉」を出せば十分
- spec-base の「捕捉先が消えた走行中 tool は cancel」は、単一版の規則と両立しない。patch 後は新しい定義が走るので、消えた捕捉先を参照するコードは存在しない。
  捕捉先の有無で cancel する理由が無く、label と locals の互換性だけで決まる（`[P 6]`）

## 7. 定期ジョブ

```
component Digest(cal: Calendar, model: Model, ch: Channel) {
  state running: Option<Occurrence> = None
  state history: List<Run> = []

  tool fire(o: Occurrence) = match running {
    None    => running <- Some(o)
    Some(_) => history <- history ++ [Skipped(o)]            重なったら飛ばす
  }
  tool finished(r: Result<Text, E>) = match running {
    Some(o) => running <- None, history <- take(100, history ++ [Finished(o, r)])
    None    => 変更なし
  }

  use tick = cal.watch(every = 1.day, at = "09:00", on_tick = fire)
  when running is Some(o) {
    run: Compose(model, o) => finished   key o.id
  }
}
```

重なりの方針は `fire` の 1 行で決まる。飛ばす（上）、待たせる（`pending` に積む）、やり直す（`running <- Some(o)` で key が変わり古い run が dispose）。

### 評価

- 方針が遷移に局所化されているのはよい。`key o.id` を付けているのは、同じ日に 2 回発火したときに別の呼び出しにするため
- `history` は State なので無制限に伸びる。`take(100, …)` を書かないと SoT が肥大する。長い履歴は store（外部 resource）に書くのが正しく、それは `finished` から `=> k` では書けない（sync tool から async 作用は起こせない）。
  「遷移の結果として外部に 1 行書く」には `when` の枝と `instant` が要り、遠回りになる。頻出するなら `state` の永続先を store にする kind（`store.list(name)` を signal として `use`）で吸収できるが、spec-base には無い（未決として記録）
- runtime が止まっていた間の発火は `cal.watch` の葉が再接続時に届ける責任を持つ。protocol の at-least-once は Katari → 葉の方向にしか書かれていないので、葉 → Katari の `send` にも連番と再送があるべき（`[P 3]` と同じ拡張で足りる）

## 8. キャンセル

親の宣言が消える cascade。§1 の Request を親が取り下げる場合を追う。

| 順 | protocol | 備考 |
|---|---|---|
| 1 | 親の render で `Request(r)` の宣言が消える | |
| 2 | ↓ を依存の逆順に発行: dispose(R·done) / dispose(R·ask) / dispose(R·ttl) | state ノードは葉を持たないので即 ↑ |
| 3 | 葉が中止して disposed を返す | human は質問を取り下げ、clock は timer を消す |
| 4 | 全て ↑ したら接頭辞 `R·` のノードが消える | |

止められない葉（決済、provider が中止できない推論）: kind が `interruptible: false` を宣言し、runtime は完了を待ってから dispose を送る。
その間、親の ↑ も待つ。plan / trace には `disposing (waiting for pay.charge)` と出る。中止できる葉が既定で、待つ葉は kind 側の明示。

- 「止めたはずの葉から結果が届く」は `[P 3]` で捨てる。`interruptible: false` の葉には dispose が発行されていないので、その完了は捨てられない。整合する
- キャンセルの意味論が「宣言が消える」だけなのは一貫していて、取り下げ・timeout・親の消滅・patch の reset が全部同じ経路を通る

## 9. 使い分けの説明

読者に説明する形にすると次のようになる。

```
tool body    : 途中を誰も見ない・変えない。入力が変われば全部やり直してよい。一括
component    : 途中を見る・変える（人間が待っている、取り下げる、引数が変わる）。入力の変化に増分で追従したい
```

§1 の承認は component（途中で取り下げる）、§4 の集約は入力次第、§6 の onboarding は tool body で書いたが、人間が数日待つ label があるので
patch のたびに migration を考えることになる。**人間を待つ label を持つ tool は、その待ちを component の `when` に出す方が運用しやすい**。
tool body は「葉が短い」ときの糖衣、と言い切ってよい。

retry の指針: 再実行は同じ address のまま宣言し直す（args の変化か `after` の依存で作り直させる）。`key attempt` は冪等キーを変えるので、
作用を伴う葉には使わない。

## 提案

1. **must** `T(args) => k` 形の宣言に label を付ける記法（`ask: T(args) => k`）。address に label が要るが、束縛変数が無い。
   既定を tool 名にすると同じ tool の 2 回宣言で衝突する。あわせて `instant x = …` の値を sync tool に流す `x => k` を許す
2. **must** 失敗は `Result<R, E>` を運ぶ 1 本の Sink。2 本にすると `instant` の束縛に E の置き場が無く、protocol の継続も 2 本になる。tool body では `await T()?` で伝播
3. **must** `send(from, sink, value)` に送信元を入れ、runtime は dispose を発行済みのノードからの送信を捨てる。
   これが無いと timeout / race / 取り下げのあらゆる遷移が「古い結果が後から届く」ケースを自分で防ぐことになる。
   葉 → Katari の send にも連番と再送を付け、at-least-once を両方向にする
4. **should** tool body に `race`（先に揃った方を採り、残りを dispose）。承認 + timeout、request + timeout が tool body で書けない
5. **should** `after x` は x の値ではなく埋まり直し（generation）に依存する。同じ値が再度埋まったときに後続が動かない
6. **must** spec-base §5 の「捕捉先が消えた走行中 tool は cancel」を削除。単一版では patch 後に新しい定義が走るので、捕捉先の有無は label / locals の互換性に含まれる
7. **should** kind の静的宣言に `interruptible: false`（完了まで dispose を送らない）と `idempotency: address`（id を冪等キーにする）を加える。`replace: forbidden` はこの上に置く
8. **nice** `for` の iteration の export を Pool として受ける形（`use rs = for … { export r = … }`）。集約が `pool` + `member` + `when` の 3 宣言から 1 宣言になる

## 仕様のまま書けたが違和感がある点

- `use pr = gh.pr(branch) after impl` で impl が作り直される間、PR resource は生きているのに継続（`when pr.merged` など）が引っ込む。正しいが予期しにくい
- 全域性の要求により、遷移が `match (state, event)` の形になりがちで、`_ => 変更なし` の行が常に付く。`[P 3]` で減るが消えない
- `history` のような伸び続ける State を store に逃がす経路が sync tool から無い。遷移の結果として外部に 1 行書くだけで `when` + `instant` になる
- 決済の retry を `key` で書くと冪等キーが変わる。仕様上は正しいが、`key` の意味を「同一性を変える」と理解していないと踏む

## 未決の問い

- `interruptible: false` の葉を持つ親が dispose を待つ間、その親の address に対する新しい宣言（同 key での再 init）はどう扱うか。待つか、別 incarnation か
- 長い履歴や監査ログのように、遷移のたびに外部へ追記したい State の置き場。`state` の永続先を store にする kind で吸収できるか
- `race` を component 形（2 つの `=> k` と全域な遷移）の糖衣と定義できるか。できるなら `par` と同様に tool body 専用の primitive にしなくてよい
