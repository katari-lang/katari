---
title: Katari v0.2 — モデルと仮想構文
description: 動的 terraform としての Katari。middleware と use、tool の等級、instant、依存 DAG、State・Pool・export、理想的な usage
---

> この文書は経緯を残すスケッチ。現行の仕様は `2026-10-01-spec.md`。

この文書は v0.2 の概念モデルと仮想構文を固定するためのスケッチで、具体的な意味論は定めない。
意味論は別文書で pool 上の LTS として与える。v0.1 のコードベースは前提にしない。

## 位置づけ

Katari v0.2 は動的な terraform である。terraform を「静的なリソースの宣言」と見ると、
それに状態・配線・component instance の動的な更新を加えたものが v0.2 になる。
React のアナロジーでは、React が DOM として解釈しているものを組織構造として解釈する DSL。

```
component d : Inputs → (resources, {key ↦ child})
runtime     : 入力（環境イベント・State）が変わるたびに d を再評価し、
              宣言された子集合の差分を init / dispose に変換する (reconcile)
```

書き手が書くのは「今の入力ならこの子たちがいるべき」だけで、init も dispose も差分から出る。
定義の差し替え (patch) は同じ State で再評価することに他ならず、reconcile と同じ操作になる。

## 核

### component と middleware

```
Component(B)     ≅  (B ⇒ Void) ⇒ Void        継続を受け取る。引数を適用済みの middleware
M : Args → Component(B)

use x = c ; rest    ≡  c (λx. rest)          bind。rest は c の下に nest し、c は rest の親になる
c ; rest            ≡  par(c, rest)          bare は葉。rest と並列
par (c₁, c₂)                                  継続が複数の親を持つ。互いに独立な use は自動で par になる
```

`Component(Void)` に `use` するのは静的エラー（継続に値が来ないので rest は到達不能）。
resource handle は component 構築子を持てる（`discord.Watch(...)`）。名前と権限を同じ handle で運ぶ。

instance に対してできることは 3 つ。これは構文ではなく概念（protocol）。

```
init d(args) → i       instance を作る。親を教える必要はない（親が子を覚える）
↓i                     dispose 命令
↑i                     dispose 完了通知。i に依存するノードが全て ↑ してから行う
```

instance に完了シグナルは無い。「終わった」は誰も言わず、宣言が消えるだけ。
dispose 命令は言語のプリミティブにはない。init / dispose はすべて他の instance の宣言の変化か、
環境側イベントの cascade として起きる。

### 依存 DAG

component body は順不同。宣言の依存は自由変数で決まり、DAG はコンパイル時に静的に構築される
（`when` の枝の選択だけが動的）。

```
宣言 d は、d の式に自由に現れる名前を束縛した宣言に依存する
```

`use x = M(args)` の継続は `x` の handle を使うので `M` に依存する。継続の親の集合が
その場所の依存 DAG で、↑ の順序はその逆順。resource とは `use` の出力のことで、
resource と instance は別のノード種ではない。DAG は木ではない（`member` で pool に入った要素には
subtree 外の読み手からの辺が載る）。

```
owner(x) = use を書いた instance          x は所有者と同じ寿命
```

### 同一性: address

component 定義は middleware の糖衣なので、実体は middleware の nesting した木で、
body 全体を包括する instance というノードは無い。同一性は nesting とは別に、address で定める。

```
address ::= (scope, key)* · label
scope   ::= component 定義の呼び出し site の label（Child、for の site、tool の呼び出し）
label   ::= body 内の構文上の名前（use の束縛変数、Child 名、await の束縛変数）
```

scope はノードではなく address の接頭辞。「Child の instance」とは接頭辞 `…·Child` を持つ
ノードの集合のことで、実体は無い。body `use a = M1; use b = M2; Child` は middleware としては
`M1(λa. M2(λb. Child))` で、この nesting が依存 DAG（寿命の順序）。address は nesting を無視して
`a`, `b`, `Child·…` で、これが同一性。

```
use c = M(...)               label = c
Child(args)                  scope = Child（同名が複数あれば key 必須）
for x in p key f(x) { }      scope = (site, f(x))
when cond { }                接頭辞を作らない。cond が偽 = 中の label が不在
let x = await T(...)         label = x。tool の pc も label（trace と plan の可読性のため）
```

`use a` を抜くと `b` の address は変わらず（keep）、`b` の依存 DAG から `a` が消える（辺の更新）。
辺の付け替えは init / ↓ を伴わない。scope の label を改名すると接頭辞ごと変わるので、
patch は明示の対応表（terraform の `moved`）を持ち、既定は同 label。plan が候補を出す。

label は定義の body 内で一意。排他でない 2 つの `when` に同じ label があれば静的エラー。

継続の呼び出しは scope 接頭辞の下でノード集合を再生成することで、address が同じものは
reconcile（引数の更新）、無いものは新規、消えたものは ↓。`state` が値の変化で継続を再度呼ぶのも
これで、middleware の意味論と reconcile は一致する。

### kind: Data と Type

```
Data ⊑ Type
Data : コピー可能。handle を含まない（数、文字列、レコード、直和、source text）
Type : handle（use の出力、Sink、Pool、Definition）を含みうる。component mode ではどの型も signal
```

区別の強制点は 1 つ: `Sink<X>` は `X : Data` を要求する。emit は子（短命）から port の所有者（長命）へ
情報を運ぶ唯一の経路なので、handle を含めない。ここから

- `tool T(a): R` の `R : Data`（`k : Sink<R>` から）
- `state s: T` の `T : Data`（State は Sink 経由でしか書けないから）
- Pool の要素型が Type でよいこと（読み手の iteration が要素のノードに依存し、先に ↑ するから）

が導かれ、`lifetime(使用者) ⊆ lifetime(所有者)` が構造的に保証される。所有権の自動巻き上げは要らない。

### tool と等級

計算はすべて `tool`。等級は body から推論される。tool は component と並ぶ primitive で、
原子的な逐次実行の単位。結果を持ち、走行中の call は version-local（patch で途中から新しいコードに切り替わらない）。

```
tool T(args): R { body }
  pure  ⊂  sync  ⊂  async
  pure  : 送信も await も無い    式の中で呼べる（key、when の条件、他の tool の引数）
  sync  : await が無い           1 遷移。port で Sink にできる。定義された body の State を書ける
  async : await がある           宣言でしか起動できない。State を書けない。dispose できる
```

型は等級を持つ: `Args → R`（sync 以下）、`Args ~> R`（async）。

sync tool の body は 1 遷移として原子的に commit される。同じ state への 2 回の書き込みは型エラー。
遷移は全域（構造的再帰）。async tool は await で区切られた sync 区間の列で、各区間に同じ規則が
適用される（区間内では State を書けない）。

component body 内で定義した sync tool は、その body の signal（発火時の snapshot）と Sink を捕捉する。
捕捉するのは address と snapshot だけなので、closure が値になることはない。State を書けるのは
この形の sync tool だけ。

```
component Triage(...) {
  state closed: Bool = false
  tool done(s: Summary) = closed <- true          sync。この body の State を書く
  ...
}
```

### Sink と port

```
port : (X → Unit) → Component(Sink<X>)        X : Data。sync tool を Sink にする
k <- x                                         送信。sync 区間でも async body でも書ける
```

Sink への送信は 1 遷移: 受け手の sync tool が走り、その書き込みと送信が commit 後に配送される。
自分の port への再入は起きない。Sink の変換（contramap、filter、両方へ）は `port` + sync tool で書ける。

イベント源は tool を受け取る。等級で意味が変わる。

```
discord.watch(ch, on_message = receive)    sync  : イベントは所有者の遷移。所有者の State を書ける
discord.watch(ch, on_message = respond)    async : イベントごとにノード。address = イベント源 · event key
```

規則: callback は、それを受け取る resource を捕捉してはならない（静的な循環になる）。
返事を送る先と受信の購読は別の resource にする（`channel` と `watch` の分離）。

```
use ch = discord.channel("general")                 export send: Sink<Text>
tool receive(m: Message) = pending <- pending ++ [m]  ch を捕捉してよい
use w  = discord.watch(ch, on_message = receive)    w は receive と ch に依存。ch は誰にも依存しない
```

処理が終わるまで要素を保持したいときは、kind が受信箱の Pool（要素に ack の Sink を持つ）を export する形もある。

React の callback を props で渡す形と同じ。違いは callback が closure ではなく
`(instance, port)` の handle であること。closure を値に入れないので永続化と patch が通る。

use の出力に Sink を含めれば、所有者から子へ信号を送れる。

```
use ch = slack.channel(name)      ch : { send : Sink<Message>, id : Text, ... }
tool relay(m: Message) = ch.send <- m
```

信号の向き（親 → 子）と handle の流れ（子の出力 → 親の継続 → さらに下）は別物で、
制限されるのは後者だけ。

### tool call: Sink 側の CPS

async tool は結果を返し、schema を持つ（AI から呼べる）。protocol 上は結果の Sink を引数に取る形で表現される。

```
tool T(a: A): R { ... return r }     protocol 上は  T(a: A, k: Sink<R>) { ... k <- r }
```

これは表現であって糖衣ではない。patch の意味論が component と異なる（走行中は version-local）。

呼び出しは caller の子（葉）の宣言で、継続は caller の port に置く。
`use` と違い、callee は継続の親にならない。どちらの機構を使うかは定義の構文カテゴリで決まり、型で判定しない。

component からの呼び出しは 2 形。

```
instant x = T(args)        結果を値として受ける（derivation）
T(args) => k               結果をイベントとして sync tool k に渡す
```

tool body の中からは `await`。protocol 上は次のように表現される。

```
let x = await T(args)
  protocol 上は  tool k_x(v) = x <- v, pc <- next
                 when pc = k_x { T(args, k_x) }     pc が進むと宣言が消え、T は dispose
```

順序: tool call は source 順 = pc 順で逐次。並列は明示する。

```
let (x, y) = await par(U(a), V(b))            同じ pc に 2 つ宣言し、2 port で join
```

`use` は独立なら自動で並列。作用は tool call を通るので逐次、資源の確保は dataflow なので並列。

### resource kind は外部

resource kind（`slack.channel` など）は runtime の外（FFI）で定義される。Katari が見るのは `Component(B)` の
export だけで、acquire / release / update は kind の中にある。component body に unmount hook は無い。

dispose 時に作用が欲しければ、終わりを決めた側がそれを宣言する。寿命は宣言が決めるので、
宣言を消す側は次の枝で後始末を宣言できる。

```
state closed = false
when not closed { Conversation(channel, user) }
when closed     { instant _ = farewell(channel, user) }
```

kind は引数ごとに in-place 更新できるかを宣言する。できなければ args の変化は release + acquire。

葉の呼び出し（http、model）は外部実行で、runtime 再起動を跨いだ exactly-once は Katari では保証できない。
runtime は開始を記録してから葉を呼び、再起動後に未完了なら kind の契約（再送 / 中断）に従う。
これは protocol の項目。Katari で kind を書けるようにする案は、composer 側の意味論に影響しないので後回し。

### 遷移はイベントでのみ起きる

```
遷移（State の書き込み）は、外部イベントか tool の完了でのみ起きる
render は State から「今何が走っているべきか」を宣言するだけ
⟹ State を書く sync tool は callback（Sink、`=> k`）としてしか呼べない。instant の右辺には置けない
```

render をきっかけに遷移を起こす形（React で useEffect から setState する形）は書けない。
遷移の条件が render の条件と memo の規則に散らばらず、どのイベントで何が変わるかが 1 箇所に書かれる。

### instant: component から tool を呼ぶ

```
instant x = T(args)          x : R。T のノードは結果を出したら終わり、x は address に Data として保持される
```

`use` と同じく、x を参照する宣言は x が埋まるまで存在しない。違いはノードの寿命と出力の保持場所だけ。

```
use x = M(args)        ノードは出力の後も生き続ける。x はノードから導出される
instant x = T(args)    ノードは出力で終わる。x は address の値
```

- 再起動後は address の値を使い、再実行しない
- args が変わればノードを作り直して埋め直す（tool は in-place 更新できない）
- 宣言が消えれば、走行中なら dispose、埋まっていれば値を捨てる
- 走行中の call は version-local。埋まった値は Data なので版に依らない

ワークフローは instant と use の DAG になり、各 instant の値が中間点になる。

```
use     branch = github.branch(repo, spec.name)
instant impl   = Implement(spec, branch)
use     pr     = github.pr(branch) after impl
instant review = Review(pr)
```

`instant` は derivation（入力で key された計算結果の存在）で、release は値を捨てるだけ。
call が外部に作ったものが call より長生きし片付けが要るなら、それは resource で `use` にする（branch、PR、channel）。
call の価値が出力の値そのものなら `instant`（推論、分析）。この線を守れば、instant の中の作用は
args に対して冪等でよく、スケジューラが依存だけで順序を決められる。

「途中」は tool body の中にしか無い。tool body の中は原子的（version-local）、外は instant で区切られている。
長く走るものや patch したいものは instant に分割する。

データ依存で表せない順序は `after` で書く。意味は「自由変数に足す」だけ。

```
instant review = Review(repo) after pr
```

作用の結果は Data として返すのが基本（PR を開く step は PR 番号を返す）。`after` は返すものが無い場合の逃げ道。
外部の条件を待つのは resource の export signal と `when`。

```
use merged = github.watch_merged(pr)
when merged.done { instant deploy = Deploy(pr) }
```

結果で分岐するのは `when x is …`。ループと retry は State（試行番号を key に含める）。
外部イベントで進むのは sync tool → State → when。tool の完了で進むのは `T(args) => k`。

## 糖衣

```
resource r = kind(args)            = use r = kind(args)
state s = init                     = use (s, set_s) = state(init)     継続を s が変わるたびに再起動 (keyed)
when c { body }                    = use _ = when(c, body)            継続を 0 または 1 回
for x in p key f { body }          = use _ = for(p, f, body)          継続を要素ごと (keyed)
port(t)                            = Sink。t は sync tool
Child(args)                        = use _ = Child(args)              出力 ⊥。何も依存しない葉
instant x = T(args)                = 出力で終わる use                  component body 内
with c = kind(args) { ... }        = use c = kind(args)               tool body 内。pc 区間の resource
```

### signal と State

この言語に定数はない。component mode では型 `T` の式は時変値（signal）で、literal は定数 signal。
tool mode では型 `T` の式は値（snapshot）。component から tool call への引数は宣言時の snapshot。

body の DAG は静的なので、signal が変わったとき再評価されるのは依存する `use` だけで、
body 全体は再実行しない。tool call の引数 signal が変わると同じ address で引数が変わるので
cancel + 再開（tool は in-place 更新できない）。resource kind は引数ごとに in-place か作り直しかを宣言する。

`state s: T = init` は signal `s` と `set_s : Sink<T>` の対（`T : Data`）。`s <- v` は `set_s` への送信で、書けるのは同じ body の sync tool の中だけ。
async tool は State を書けない。結果を返し、所有者側の instant か sync tool が扱う。

### List と Pool

```
List<T>   T : Data。普通の signal。要素の追加は所有者の sync tool が書く

p : Pool<B>                      所有者が宣言。p.admit : Admit<B> は書き込み能力（handle として下に渡す）
member p.admit x                 x : B は宣言者の body の use の出力。pool に入っている間 = この宣言が有効な間
for x in p key f(x) { body }     x : B を束縛する。body は x のノードに依存する
```

`member` は handle を所有者側へ見せる唯一の機構。読み手の iteration は宣言者の subtree 外にいるが、
依存 DAG に `iteration → x` の辺が載るので、宣言者の ↑ は iteration の ↑ の後になる。
DAG が木でないのはこのため。

handle が body に入る経路は params、use の出力、`for` の束縛の 3 つ。

### export

component の出力は `export` を付けた宣言の record。

```
component Team(slack: Slack, spec: TeamSpec) {
  export use channel = slack.channel(spec.name, incoming)
  export use memory  = store.namespace(spec.name)
  export state load: Int = 0
  export tool incoming(m: Message) = load <- load + 1
  Digest(channel, every = 1.day)
}
Team : Args → Component({ channel: Channel, memory: Namespace, load: Int, incoming: Message → Unit })
```

- export が無ければ `Component(Void)`
- export は body の top-level のみ。`when` の中には書けない
- `export state` は signal（読み）を出す。setter は出さない。`export tool` は sync なら Sink 相当、async なら定義を出す
- `self ≡ { e₁ = e₁, …, eₙ = eₙ }`（e_i は export された名前）。自由変数は全ての export なので、
  `self` を使う宣言は全ての export の後になる。`member admit self` の発火と、親の `use t = Team(...)` の
  継続の呼び出しは同じ時点（export record が揃った時点）
- 実際に待つのは `export use` だけ。`export state` は初期値、`export tool` は定義で即座に揃う
- export が `self` に依存すると循環で、静的エラー
- `use` の init 完了は継続を呼ぶイベントで、再 render を引き起こす。値が揃った部分から宣言が現れるので、
  render に未知値は現れない

resource kind の interface は component の export 集合と同じもの。builtin の `slack.channel` も
export を持つ component で、attrs = export された signal、送信口 = export された Sink。

### tool body の protocol 表現

runtime が tool をどう永続化するかの表現。言語上の糖衣ではない（patch の意味論が異なる）。

```
tool T(a): R {
  let x = await U(a)
  with c = channel(x) {
    let y = await V(c)
  }
  return f(x, y)
}
  ⟹
component T(a, k: Sink<R>) {
  state pc = k₁                               pc は待っている label
  state x, y                                  await を跨ぐ局所変数は State（∴ Data 限定）
  tool k₁(v) = x <- v, pc <- k₂
  tool k₂(v) = y <- v, pc <- done, k <- f(x, v)

  when pc = k₁ { U(a, k₁) }
  when pc = k₂ { use c = channel(x)
                V(c, k₂) }
}
```

帰結:

- await を跨ぐ変数は Data なら State に、handle なら `with` の resource に落ちる。長い await 中に握っている resource は DAG 上にそのまま見える
- sub-call の cancel は宣言の消滅。結果を消費した時点で dispose される
- tool は await 境界で checkpoint される（sync 区間が 1 遷移で State が durable）
- 失敗は第 2 の Sink。try/catch は err port の sync tool
- ループは pc の遷移。再帰 tool は自分を sub-call として宣言する

| | component body | sync tool | async tool |
|---|---|---|---|
| use（子・resource） | ○ | × | `with` のみ |
| await | × | × | ○ |
| State の書き込み | × | ○ | × |
| 送信 | × | ○ | ○ |
| 停止性 | — | 必須 | 区間ごとに必須 |

## `{}` の意味

`{}` の意味は外側の定義のモードで決まる（字句的）。

```
component / when / for / agent / with (component 内)  →  body: 継続 (B ⇒ Void)。宣言の集合。順序なし
tool / with (tool 内)                                  →  block: 逐次。順序あり
```

sync tool は `=` の右に式 1 つでも書ける。mode は component / tool の 2 つ。

## 仮想構文

```
component Name(params) {
  [export] use r = kind(args)             resource
  [export] state x: T = init              T : Data
  pool p: Pool<B>
  member admit x
  [export] instant x = T(args)            tool call。x : R
  T(args) => k                            tool call。結果を sync tool k に渡す
  [export] tool t(params): R = e          body 内の tool。sync ならこの body の State を書ける

  Child(args)                             子 instance
  when cond { ... }
  for x in p key f(x) { ... }
}

tool Name(params): R { 逐次 }
```

式は純粋。ループは `for` 内包のみ。逐次構文（`await`）は tool の中にしかない。
順序を書きたければ State 機械にするか tool にする。

## 理想的な usage

サポート組織。チャンネルからチケットが来て、分類し、担当チームの agent が対応する。

```
component Support(slack: Slack, teams: List<TeamSpec>) {
  use inbox = slack.channel("support")
  state tickets: List<Ticket> = []
  tool incoming(m: Message) = tickets <- tickets ++ [ticket_of(m)]
  use w = slack.watch(inbox, on_message = incoming)

  pool members: Pool<TeamHandle>
  for spec in teams key spec.name {
    Team(slack, spec, members.admit)
  }
  for t in tickets key t.id {
    Triage(t, members)
  }
}

component Team(slack: Slack, spec: TeamSpec, admit: Admit<TeamHandle>) {
  export use channel = slack.channel(spec.name)
  export use memory  = store.namespace(spec.name)
  export state spec  = spec
  member admit self
  Digest(channel, every = 1.day)
}

component Triage(ticket: Ticket, teams: Pool<TeamHandle>) {
  instant name = Classify(ticket, names(teams))
  state closed: Bool = false
  tool done(s: Summary) = closed <- true

  when not closed {
    for t in teams key t.spec.name when t.spec.name == name {
      Handle(t, ticket, done)
    }
  }
}

tool Classify(ticket: Ticket, teams: List<Text>): Text {
  let answer = await ai.infer(model, prompt(ticket, teams), schema = Text)
  return answer
}

component Handle(team: TeamHandle, ticket: Ticket, done: Sink<Summary>) {
  agent Solver(model = team.spec.model, goal = ticket.body, finished = done) {
    tool Search(team.memory)
    tool Reply(team.channel)
  }
}
```

読み方:

- `Support` が生きている間だけ `inbox` がある。`Support` が消えれば `members` も `Triage` も消える
- `tickets` は Data の List。`watch` が sync tool `incoming` に届け、それが書く。要素ごとに `Triage` が宣言される
- `Team` は自分の export record を `member` で `members` に入れる。`Team` が消えれば要素も消え、その要素に依存する `Handle` が先に ↑ する
- `Classify` は `instant`。`name` が埋まるまで `for` は存在しない。Sink は Data しか運ばないので、返すのは名前
- `Handle` の `done` は `Triage` の port。孫の `Solver` にそのまま渡している
- `Team` の `channel` は `Team` の export として pool に入り、`for` の束縛で `Handle` に届く。handle は params、use の出力、`for` の束縛でしか動かない
- resource kind の宣言は provider handle（`slack`）を要求する。名前が使えることと権限があることは別

agent は builtin component。tool は子として宣言され、AI の呼び出しごとに runtime が
`for call in pending key call.id { T(call.args, answer(call.id)) }` 相当を宣言する。
tool 作者は逐次に `tool T(args): R` を書くだけでよい。

### ターン: 応答中に来たメッセージを次にまとめる

```
component Bot(discord: Discord, model: Model) {
  use ch = discord.channel("general")
  state turn: Option<(Int, List<Message>)> = None
  state pending: List<Message> = []

  tool receive(m: Message) = match turn {
    None    => turn <- Some((0, [m]))
    Some(_) => pending <- pending ++ [m]
  }
  tool finish(_: Unit) = match (turn, pending) {
    (Some((n, _)), []) => turn <- None
    (Some((n, _)), ms) => turn <- Some((n + 1, ms)), pending <- []
  }
  use w = discord.watch(ch, on_message = receive)

  when turn is Some((n, batch)) {
    Turn(ch, model, batch) key n => finish
  }
}

tool Turn(ch: Channel, model: Model, batch: List<Message>) ~> Unit {
  let answer = await ai.infer(model, prompt(batch))
  await ch.send(answer)
}
```

遷移は `receive`（メッセージの到着）と `finish`（ターンの完了）の 2 箇所だけ。render は
「ターンがあれば Turn が走っている」を宣言する。ターン番号を key に入れるのは、連続したターンで
batch が偶然同じでも別の呼び出しとして扱うため。

## 動的な attach

component 定義は resource として instance に取り付ける。我々が言語をデプロイするのは
root に対して同じことをしているにすぎない。

```
Text            : Data        source。snapshot。どこへでも運べる
Definition<I>   : Type        check 済みで linked な定義。I = interface（params の型）
                              use の出力なので owner の寿命に従い、下にしか渡せない

use m = module(src_m)                              依存なし
use d = check(src_d, env = { m }, i)               d → m の依存辺が DAG に載る
when d.status is Ok { d(args) }                    mount は handle を使った子宣言

root:  runtime が builtin module の handle を env として与える。
       katari deploy は root が持つ定義の差し替え
```

定義が参照する名前（型、関数、他の定義、resource kind）は check 時に `env` の handle に束縛される。
名前の参照は実行時参照なので Data にはならず、所有として DAG に現れる。
使える名前と使える権限は同じ機構（下向きの handle 渡し）で決まる。

JS の eval と違い、ambient scope・型の欠如・寿命の欠如・closure の持ち込みは、
それぞれ規則 4・`check`・親の宣言・Data の定義から構造的に排除される。

tool は Data しか返せないので、AI 生成が返すのは `Text`。定義にするのは host が宣言する。

```
tool Generate(spec: Text, i: Interface): Text { ... ai.infer ... }

component Plastic(spec: Text, env: Env, args: I) {
  state src: Option<Text> = None
  tool generated(t: Text) = src <- Some(t)

  when src is None    { Generate(spec, I) => generated }
  when src is Some(t) {
    use d = check(t, env, I)
    when d.status is Ok     { d(args) }
    when d.status is Err(e) { Regenerate(spec, e) => generated }
  }
}
```

### reconcile と plan

同じ key に別の定義が入ったとき、「別物か」は判定できないので常に reconcile を試みる。
State を捨てたければ key を変える（明示）。

```
plan  : (Pool, Defs) → Diff        render を commit せずに走らせたもの
Diff  ::= List<keep i | patch i (State 互換) | reset i (State 非互換) | init | dispose i
              | recheck d | recheck-failed d (errors)>
```

reconcile は定義と State の純粋関数なので、plan は同じ計算を commit なしで行うだけで得られる。
定義 `m` を差し替えると、`m` に依存する定義は再 check され、そこから mount された instance が
reconcile される。影響範囲は DAG の依存辺を辿ったもので、cascade で dispose される resource も含む。
動的 attach では host が `plan` を呼び、Diff を見てから mount できる。

State 互換の既定は State レコードの構造的部分型（増えた変数は init、消えた変数は捨てる、
型が変わった変数は非互換）。非互換を patch にしたければ移行関数を書く。

## 永続化・回復・patch

- runtime は server 側で LTS の状態（instance の State、resource、pool）を永続化しながら実行する
- 回復 = 同じ定義で reconcile。tool も component なので一様
- patch = 定義を差し替えて同じ State で reconcile。component は State の形が合えばそのまま移る。
  tool は逐次の列で「途中」があるので、走行中の call は開始時の版で完走する（version-local）。
  SoT は `{ address ↦ (State, 定義の版) }`。reconcile で tool の宣言が keep なら古い版のまま続き、
  新規の call は新しい版。古い版はそれを指すノードが無くなったら消える。
  plan に「版 v の call が N 個走行中」と出る。完走を待つ（drain）か key を変えて cancel + 再開するかは明示の操作
- 版を跨いで運ぶのは State・resource の生存集合。走行中の tool は運ばない（古い版で完走する）

## 未決

- sync 区間の停止性の保証方法（構造的再帰に限るか、fuel か）
- Pool の render 依存の層化。寿命 DAG は非巡回だが、render 依存（pool の読み → その pool への member 宣言）は
  巡回しうる（`for x in p { … member p.admit … }`）。巡回は静的エラーとし、巡回的な成長は sync tool を挟んで
  commit を跨いで書く方針。チェックは寿命 DAG とは別のグラフに対する専用処理になる
- 逐次構文をどこまで貫くか。component body に `sequence { a; b; c }` を step State の自動生成として足すか
- agent と human を専用構文にするか、builtin component に留めるか
- `key` を省略したときの既定の同一性
- patch 時の State 形状の互換規則（部分型で足りるか、移行関数を書かせるか）
- `TeamSpec` のように handle を含むレコードを `List` で受け渡すときの kind 規則の細部
- `Env` の形（module handle の record、builtin module の粒度）と `Interface` の Data 表現
- `moved` 対応表の構文と、plan が候補を出す規則
- 葉の呼び出しの再起動契約（再送 / 中断）の protocol 上の表現
- Katari で kind を定義する `kind` カテゴリ（env の capability として与える案）
