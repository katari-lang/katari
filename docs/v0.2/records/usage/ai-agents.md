---
title: usage 評価 — AI エージェント、tool、動的 attach
description: spec-base に対して AI 周りの usage を仮想構文で書き、runtime の挙動と落とし穴を確かめる
---

対象は `2026-09-30-spec-base.md`。各節は usage のコード、runtime の挙動、評価、提案の順に書く。
提案は末尾にまとめる。

## 前提: 葉と agent の層

boundary principle に従い、外部の葉は `ai.infer`（model を 1 回呼ぶ）だけにし、agent のループは
Katari の stdlib（async tool）で書く。会話履歴は tool の locals になり、Katari 側で永続化・patch の対象になる。

```
ai.infer : (model: Model, messages: List<Msg>, tools: Tools, partial?: Sink<Text>) ~> Step
Step     = Say(text: Text) | Call(calls: List<{ id: Text, name: Text, args: Json }>)
Tools    = { name ↦ tool handle }        handle の params は Data、結果は Data（AI が引数を与えるため）
invoke   : (Tools, name: Text, args: Json) ~> Json        名前で dispatch する builtin
```

## 1. agent

### コード

```
tool Solve(model: Model, goal: Text, tools: Tools, progress: Sink<Progress>) ~> Text {
  var messages = [system(goal)]
  loop {
    let step = await ai.infer(model, messages, tools)
    match step {
      Say(text) => return text
      Call(calls) => {
        progress <- Calling(calls.map(c => c.name))
        let results = await for c in calls { invoke(tools, c.name, c.args) }     並列。iteration ごとに address
        messages = messages ++ [assistant(step)] ++ results.zip(calls).map(tool_result)
      }
    }
  }
}
```

呼び出し側は 2 形のどちらでもよい。

```
instant summary = Solve(team.model, ticket.body, { search, reply }, progress = port(on_progress))
Solve(team.model, ticket.body, { search, reply }, progress = port(on_progress)) => done
```

`agent Solver(model, goal) { tool … }` の専用構文は、tools の record を作って `Solve` を呼ぶ糖衣に
留める。意味論は増やさない。

### runtime の挙動

`Handle` が render され `Solve` が宣言されたところから。address は `Handle·summary` を接頭辞にする。

```
render      Handle·summary を init。Solve の状態 = loop₀·infer {}（label · 反復番号）
Katari→葉   init(Handle·summary·loop₀·infer, { model, messages, tools }, k)
葉→Katari   send(k, Call([{ id: "c1", name: "search", args: {...} }]))
遷移        Solve の状態 = loop₀·results { messages, calls }。for の子を宣言
render      Handle·summary·loop₀·results·(c1) を init（search は Katari の tool）
              search の body が kb.query を await → 葉の init
葉→Katari   send(k', hits)
遷移        search が完了し結果を send。loop₀·results の for が揃う
遷移        Solve の状態 = loop₁·infer {...}。loop₀ 配下の宣言が消え、search のノードは dispose
...
葉→Katari   send(k, Say(text))
遷移        Solve が完了。summary が埋まる。継続（summary を使う宣言）が現れる
```

tool call は「runtime が `for call in pending key call.id` を宣言する」のではなく、agent ループ自身が
`await for` で宣言する。外部の agent（JS 側でループを持つ形）にした場合は、対称な protocol で
外部が親として `init(id, args, k)` を Katari の tool に送る形になり、Katari 側からは同じ木に見える。

### 評価

- `instant` / `=> k` の使い分けは、結果を構造（次の宣言）に使うか遷移に使うかで決まり、直感的
- ループの反復ごとに address が変わる必要がある。同じ label を再利用すると、`at-most-once` の葉が
  id（= address）で重複除去し、2 回目の反復の呼び出しを捨てる。spec-base の「ループは pc の遷移」だけでは
  address が決まらない（提案 1）
- `await for`（動的な個数の並列）が要る。`par(U, V)` はタプルで個数固定（提案 2）
- tool の失敗の形が決まっていない。model に返す tool_result はエラーも文字列にするので、`Result<R, E>` を
  値として受けられればよい（提案 3）
- 会話履歴が locals なので、patch で label `loop_n·infer { messages }` の互換判定に乗る。messages の型を
  変えると migration が要る。妥当

## 2. tool 作者の体験

### コード

```
tool Search(kb: Knowledge, q: Text) ~> List<Doc> {
  let hits = await kb.query(q, limit = 5)
  return hits
}

tool now(): Text = clock.now                    sync。即答

tool Refund(payments: Payments, approver: Human, order: OrderId, amount: Int) ~> Result<Receipt, Text> {
  let ok = await approver.confirm("Refund " ++ amount ++ " for " ++ order)
  if not ok { return Err("declined") }
  let r = await payments.refund(order, amount)
  return Ok(r)
}
```

agent に渡すときは Type の引数を先に束縛する。

```
tools = { search = Search(kb), refund = Refund(payments, approver), now }
```

schema は残りの params（全て Data）と結果型から導出する。docstring は tool の doc コメント。

### runtime の挙動（Refund の人間待ち）

```
render      Solve·loop₂·results·(c7) を init。Refund の状態 = confirm {}
Katari→葉   init(…·(c7)·confirm, { approver, text }, k)      human kind。UI に質問が出る
（3 日経過。runtime は再起動してもよい。葉は id で質問を保持する）
葉→Katari   send(k, true)
遷移        Refund の状態 = refund { }。payments.refund を宣言
```

その間に agent 全体が dispose された場合（ユーザーが依頼を取り下げた）:

```
render      Handle·summary の宣言が消える。依存の逆順で ↓
Katari→葉   dispose(…·(c7)·confirm)                          UI から質問が消える
葉→Katari   disposed(…)
```

### 評価

- Type の引数を束縛して AI 向けの tool にする操作が必要。body 内に `tool search(q: Text) ~> List<Doc> = await Search(kb, q)`
  と書けば済むが、毎回 async のラッパーを書くのは冗長（提案 4）
- sync tool（`now`）は 1 遷移で答える。model から見れば即答の tool。等級は schema に影響しない。噛み合う
- 人間待ちは葉の中。tool の状態は label `confirm {}` で止まる。patch は label 互換で判定される。dispose で質問が
  取り下げられるのは、v0.1 の「答えられる escalation が parked のまま残る」問題が構造的に消えている

## 3. ユーザーごとの agent（spawn と per-AI setup）

### コード

```
component Desk(slack: Slack, store: Store, models: Models) {
  use ch = slack.channel("help")
  state inbox: Map<UserId, List<Message>> = {}
  tool received(m: Message) = inbox <- inbox.push(m.user, m)
  tool consumed(u: UserId, ids: List<MsgId>) = inbox <- inbox.remove(u, ids)
  use w = slack.watch(ch, on_message = received)

  for u in inbox.keys key u {
    Assistant(u, ch, inbox[u], consume = port(ids => consumed(u, ids)), store, models)
  }
}

component Assistant(u: UserId, ch: Channel, messages: List<Message>, consume: Sink<List<MsgId>>,
                    store: Store, models: Models) {
  use ws    = store.workspace("assistant/" ++ u)                    per-AI の記憶
  use model = models.for_user(u)                                     per-AI の provider / credential
  state turn: Option<(Int, List<Message>)> = None
  tool start(_: Unit) = turn <- Some((next_turn_no(turn), messages))
  tool finish(_: Unit) = turn <- None, consume <- ids_of(turn)
  ...（ターンの制御は chat-bots の評価と同じ）
  when turn is Some((n, batch)) {
    Solve(model, persona(u) ++ prompt(batch), { remember = ws.put, recall = ws.get, reply = ch.send_as(u) }) key n => finish
  }
}
```

### 評価

- v0.1 の `spawn` の `workspace` / `persona` / per-AI provider は、全部 `Assistant` の body の `use` と引数になる。
  「per-AI に任意の handler 下で走らせる」は子の body に何を書くかの問題になり、spawn の特別な引数は要らない
- 親の inbox を子が消費するには Sink（`consume`）を下に渡す。props down / callback up の形で、React と同じ。
  子が親の State を直接書けないのは正しい制約
- `for u in inbox.keys` は、inbox が空になった user の Assistant を dispose する。残したければ `users` を別の State に持つ。
  宣言が消えることが寿命の終わりであることが素直に効いている
- `models.for_user(u)` は resource（credential を持つ）。子の中で `use` するので寿命 ⊆ Assistant。妥当

## 4. agent 同士の協調

### orchestrator（子として呼ぶ）

```
tool Researcher(model: Model, kb: Knowledge, q: Text) ~> Text =
  await Solve(model, "Research: " ++ q, { search = Search(kb) }, progress = discard)

instant plan = Solve(model, goal, { research = Researcher(model, kb), write = Writer(model) })
```

`Researcher` の呼び出しは orchestrator の `loop_n·results·(id)` の子。寿命 ⊆ orchestrator の call。
orchestrator が dispose されれば研究中の agent も消える。直感どおり。

### 対等な agent（互いに話す）

```
component Team(models: Models) {
  pool peers: Pool<Peer>
  Analyst(models, peers, peers.admit)          自分を peers に入れ、peers を読む
  Critic(models, peers, peers.admit)
}
```

`Analyst` は `member admit self` で `peers` に入り、`for p in peers` で相手を読む。**同じ pool を書いて読む**ので、
spec-base 7 の未決（render 依存の層化）にそのまま当たる。Team 内で互いを見せる構成は agent の基本形なので、
ここは未決のままにできない（提案 5）。

代替は mediator。親が Data の名簿と router を持つ。

```
component Team(models: Models) {
  state mail: Map<Name, List<Note>> = {}
  tool post(n: Name, note: Note) = mail <- mail.push(n, note)
  Analyst(models, inbox = mail["analyst"], send = port(post))
  Critic(models,  inbox = mail["critic"],  send = port(post))
}
```

これは書ける。pool の自己登録より 1 段冗長だが、通信が Data（Note）に限られ、子同士の寿命が独立になる。

## 5. 記憶（store）と State の住み分け

```
use ws = store.workspace("assistant/" ++ u)          resource。export: get, put, list（葉の tool）, watch(key): signal

tool remember(k: Text, v: Text) ~> Unit = await ws.put(k, v)        AI tool
use notes = ws.watch("notes")                                        component mode で読む signal
```

| | State | store |
|---|---|---|
| 何を持つか | 構造を決める Data（何が宣言されているか） | 内容（AI の記憶、ユーザーの設定） |
| address | 定義の address に紐づく | ユーザーが付けた key |
| 版を跨ぐ | patch の規則（keep / migrate / reset） | 生存集合。key 変更・再デプロイで残る |
| 誰が書く | 同じ body の sync tool | 葉の tool（誰でも、handle があれば） |

住み分けは明確。State に記憶を入れるとリセットで消えるので、記憶は store、が指針になる。

## 6. streaming と途中経過

```
component Chat(ch: Channel, model: Model) {
  state draft: Text = ""
  tool partial(t: Text) = draft <- draft ++ t
  tool done(_: Text) = draft <- ""
  when turn is Some((n, batch)) {
    Solve(model, prompt(batch), tools, progress = port(on_progress), partial = port(partial)) key n => done
  }
  export state draft                     UI は signal を描くだけ（presentation as data）
}
```

`ai.infer` が `partial` Sink に断片を send する。1 断片 = 1 遷移で、`draft` が伸びる。UI は export された
signal を読む。tool の途中で Sink に送る形で足りる。

- 断片が多いと遷移が多い（1 秒に数十）。runtime の遷移コストが問題になりうるが、意味論の問題ではない
- Sink は Data しか運ばないので、断片は Text。妥当

## 7. MCP 相当

```
use srv    = mcp.serve(listen, tools = { search = Search(kb), now })      公開。resource
use remote = mcp.client(url, auth = oauth.token(cred))                    取り込み。resource。export tools: Tools

instant answer = Solve(model, goal, local_tools ∪ remote.tools)
```

- serve: 外部クライアントの呼び出しは、葉が親として Katari の tool を `init` する（agent の外部版と同じ形）。
  serve を dispose すると走行中の呼び出しも dispose される
- client: `tools` は接続後に揃う export（signal）。`Solve` の宣言は `remote.tools` に依存するので、揃うまで現れない。
  tool 集合が動的に変わる（server 側の更新）と `Solve` の args が変わり、走行中の call は replace される。
  会話の途中で tool 集合が変わったときにやり直すのは望ましくない。呼び出し時の snapshot を固定する形が要る（提案 6）
- どちらも resource。妥当

## 8. 動的 attach

### コード

```
component Plastic(spec: Text, env: Env, model: Model, args: I) {
  state src: Option<Text> = None
  tool got(t: Text) = src <- Some(t)
  when src is None { Generate(model, spec, describe(I), env) => got }
  when src is Some(t) {
    use d = link(t, env, I)               検証済みの Text を link する。失敗しない
    d(args)
  }
}

tool Generate(model: Model, spec: Text, iface: Text, env: Env) ~> Text {
  var errors = []
  loop {
    let t = await ai.infer_text(model, prompt(spec, iface, errors))
    match await validate(t, env, I) {          Data の結果。link しない
      Ok(())  => return t
      Err(es) => errors = es
    }
  }
}
```

### runtime の挙動

```
遷移        got(t)。src = Some(t)
render      Plastic·d を init。link は env の module handle に依存（d → m の辺）
遷移        d が揃う。継続 d(args) が現れる。生成された定義の body が Plastic·d·… の下に宣言される
```

生成し直す（同 key 別 def）:

```
遷移        got(t')。src = Some(t')
render      Plastic·d の args が変わる。link は update 不可なので replace: dispose(d) → init(d, t')
              Plastic·d·… 配下は新しい定義で reconcile。address が同じノードは State の互換判定（keep / reset）
plan        差分が表示される。人間のデプロイと同じ
```

デプロイ:

```
root:  use program = link(bundle, env = builtins, RootI)
       program(config)
katari deploy  =  bundle への送信 + migration。上と同じ経路
```

### 評価

- `check` を「validate（tool、Data の結果）」と「link（resource、失敗しない）」に分けないと、失敗に反応する遷移が
  render 起点になる（`when d.status is Err`）。spec-base の `check` は分ける（提案 7）
- `Definition<I>` の `I` を値にすると型を Data に反映する必要が出る。`I` は静的な型のままにし、AI 向けには
  `describe(I): Text` で文字列化する。`Interface` の Data 表現は要らない（提案 8）
- env は module handle の record。生成コードが `slack.channel` の名前を使えるかは env、実際に channel を作れるかは
  args の `slack` handle。2 系統が同じ機構（handle の下方向渡し）で運ばれている。確認できた
- 「我々のデプロイ = root への同じ操作」は上のとおり成立する

## 9. per-AI の予算

```
use m = models.anthropic(cred)
use budgeted = model.with_budget(m, tokens = 200_000)        resource。export: model: Model, remaining: Int
Assistant(u, …, model = budgeted.model)
```

- `budgeted.model` を渡された子は元の `m` に触れない。handle が下にしか流れないので、予算を迂回できない
- 予算超過は葉（`ai.infer`）の失敗として tool に返る。tool の失敗の形（提案 3）に依存する
- `remaining` は signal。`when budgeted.remaining < 1000 { Warn(...) }` のように構造で反応できる

## 提案

1. **must** ループの反復は address を拡張する。`loop` の各反復に暗黙の番号 key を付け、反復内の await の address を
   `label · n` にする。同じ address の再利用は at-most-once の葉で呼び出しが捨てられる
2. **must** 動的な個数の並列 `await for c in list { … }`。結果は List。`par` はこれの固定長の場合
3. **must** tool の失敗の形を決める。`~> Result<R, E>` を値として返す形を基本にし、`throw` / `try` は第 2 の Sink への糖衣。
   agent は失敗を tool_result として model に返すので、値として受けられる必要がある
4. **should** tool の部分適用 `Search(kb)` : `Text ~> List<Doc>`。Type の引数を先に束縛して AI 向け schema を作る
5. **must** Pool の自己登録（書いて読む）の扱いを決める。agent team の基本形。層化で弾くなら mediator を
   stdlib の形（`mailbox`）で用意する。許すなら、要素の自分自身を除いた読みなど単調性の条件を定める
6. **should** 走行中の tool call の args を snapshot として固定する規則。spec-base 1.6 の「宣言時の snapshot」を
   「同じ address の走行中は args の変化で replace しない」まで明確にするか、`tools` のような集合の変化を
   次の反復から反映する形にする
7. **must** `check` を `validate`（tool、`Result<Unit, Errors>`）と `link`（resource、失敗しない）に分ける
8. **should** `Interface` を Data にしない。`I` は静的な型、`describe(I): Text` で AI に渡す

## 違和感

- `Assistant` が親の inbox を Sink で消費させる形は書けるが、「子が処理し終わったメッセージを親が消す」の
  定型が毎回出る。kind が ack 付き Pool を export する形と、どちらを stdlib の既定にするか決めたい
- tool の Type 引数の束縛（提案 4）が無いと、agent に渡す tool の定義が body 内の async ラッパーだらけになる
- `Solve` のような stdlib の async tool の locals（messages）が patch の互換判定に乗る。stdlib の更新で
  migration が要求されうる。stdlib の tool の locals は「常に reset してよい」と宣言できる仕組みがあると楽

## 未決の問い

- agent の tool 呼び出しで、model が同じ id を 2 回出したときの address 衝突（`(id)` の key）。runtime が
  連番を足すか、schema で禁止するか
- `mcp.serve` のように外部が親になる場合、外部が宣言した Katari のノードの address をどう付けるか
  （`srv·(call, id)` を Katari が付ける形でよいか）
- streaming の遷移頻度の上限。意味論ではなく runtime の設計項目
