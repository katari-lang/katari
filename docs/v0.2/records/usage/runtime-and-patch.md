---
title: usage 評価 — runtime、patch、境界プロトコル、運用
description: spec-base の規則で外部 component・reconcile・patch・再起動・Pool・観測・テストを実際に書き、困る点と最小の変更を挙げる
---

`2026-09-30-spec-base.md` の規則をそのまま使って書く。各節の末尾に判定（困らない / 変更が要る）を置く。

## 1. 外部 component（JS）3 種

protocol（spec §3）を TypeScript 側から見ると、host は次の 4 つの入口と 3 つの出口を持つ。

```ts
interface Host {
  // 入口（Katari → host）
  init(id: Id, args: Data, cont: Id): void       // cont は host が召喚してよい継続の id
  update(id: Id, args: Data): void
  dispose(id: Id): void
  receive(sink: Id, value: Data): void            // host が所有する Sink への send
  // 出口（host → Katari）
  emit: {
    init(cont: Id, output: Data): void            // 継続の召喚。output に含める Sink は host 所有の address
    update(cont: Id, output: Data): void          // 出力の変化（attrs）
    send(sink: Id, value: Data): void             // args で受けた Katari 側 Sink への送信
    disposed(id: Id): void
  }
}
```

Sink は address で同定される。host が所有する Sink は `id · "send"` のような address を host が output に入れて返す。
Katari 側 Sink は args の中に address として届く。方向に依らず `send(address, value)` で統一される。

### 1.1 resource: `slack.channel`

```ts
kinds["slack.channel"] = {
  updatable: ["topic"],                       // name は update 不可（replace）
  async init(id, args, cont) {
    let st = await db.get(id)                  // 同じ id への再 init は再取得
    if (!st) { st = { channelId: await slack.findOrCreate(args.name), cont }; await db.put(id, st) }
    emit.init(cont, { id: st.channelId, send: sinkOf(id, "send") })
  },
  async update(id, args) { await slack.setTopic((await db.get(id)).channelId, args.topic) },
  async receive(sink, value) {
    if (sink.port === "send") await slack.post((await db.get(sink.owner)).channelId, value)
  },
  async dispose(id) {
    const st = await db.get(id)
    emit.dispose(st.cont); await awaitDisposed(st.cont)   // 自分の継続を先に片付ける
    emit.disposed(id)                          // channel 自体は消さない（kind の判断）
  },
}
```

Katari 側の時系列（`use ch = slack.channel("general"); rest`）:

```
K → J   init(Bot·ch, {name:"general"}, cont = Bot·ch·k)
J → K   init(Bot·ch·k, {id:"C01", send: Bot·ch·send})       rest の宣言がここで現れる
K → J   send(Bot·ch·send, "hello")                           rest の中の ch.send <- "hello"
K → J   dispose(Bot·ch)                                      Bot の宣言が消えた
J → K   dispose(Bot·ch·k)                                    rest を先に片付ける
K → J   disposed(Bot·ch·k)                                   rest 配下が全て ↑ した後
J → K   disposed(Bot·ch)
```

### 1.2 イベント源: `slack.watch`

```ts
kinds["slack.watch"] = {
  async init(id, args, cont) {
    const sub = slack.subscribe(args.channel.id, m => emit.send(args.on_message, m))
    await db.put(id, { sub, cursor: sub.cursor })
    emit.init(cont, {})                        // 出力は空。継続は Unit で召喚される
  },
  async dispose(id) { (await db.get(id)).sub.close(); emit.disposed(id) },
}
```

`args.on_message` は Katari 側の sync tool を `port` で包んだ Sink の address。callback は `ch` を捕捉してよいが
`w` 自身は捕捉できない（spec §2.4）ので、`slack.watch(ch, on_message = receive)` の依存は `receive → ch`、`w → {ch, receive}` で循環しない。

### 1.3 tool: `http.get`

```ts
kinds["http.get"] = {
  async init(id, args, _cont) {                // 継続は召喚しない（Component(Void)）
    await db.put(id, { started: true })        // 再起動契約のために開始を記録する
    const r = await fetch(args.url)
    emit.send(args.k, { status: r.status, body: await r.text() })
    await db.put(id, { done: true })
  },
  async dispose(id) { abort(id); emit.disposed(id) },
}
```

`instant r = http.get(url)` の時系列:

```
K → J   init(Bot·r, {url, k: Bot·r·k}, cont = Bot·r·_)
J → K   send(Bot·r·k, {status:200, …})        runtime が address Bot·r に値を保存し、instant 完了
K → J   dispose(Bot·r)                         instant の脱糖で宣言が消える
J → K   disposed(Bot·r)
```

1 回の tool call が init / send / dispose / disposed の 4 メッセージになる。

### 1.4 host が落ちて復帰するとき

- runtime は id ごとに送信済みメッセージに連番を付け、ack が返るまで再送する。host は `(id, seq)` で重複を除く
- host は自分の db から復帰する。channel は `channelId` を持っているので何もしない。watch は `cursor` から購読を張り直す
- tool は `started && !done` のとき、**やり直すか中断を報告するかを kind が決める**。spec-base はこれを未決にしている。
  `http.get` はやり直せるが、`payment.charge` はやり直せない。どちらの場合も結果 Sink に何かを送らないと
  caller の tool が永遠に待つ

判定: 変更が要る。**tool の結果は `Result<R, Fault>` を protocol 上の形とし、`Fault` に `interrupted` を含める**。
kind は再起動時の既定（retry / interrupt）を静的に宣言する。`await` は Ok を返し、Fault は try/catch で受ける。

### 1.5 id = address で冪等性を保てるか

address はプログラムが選んだ key を含むので安定している。`when` の反転で同じ address が dispose → init されるとき、
host には同じ id で 2 回目の init が届く。runtime は `dispose` の ack（disposed）を待ってから `init` を送るので、
順序は保証される。host は「同じ id への再 init = 同じものの再取得」として扱う。決済 kind が address で at-most-once を
守るなら、`when` の反転で二重決済は起きない。「別の決済」にしたければ key を変える、が規則になる。

判定: 困らない。ただし runtime は id ごとの送信履歴を持っているので、plan で **「以前 init されたことのある id への init」を注記できる**。決済のような kind ではこの注記が事故を防ぐ。

## 2. reconcile の 1 ステップ

例（spec-base §2 の Support / Triage を使う）。

```
component Support(slack: Slack, teams: List<TeamSpec>) {
  use inbox = slack.channel("support")
  state tickets: List<Ticket> = []
  tool incoming(m: Message) = tickets <- tickets ++ [ticket_of(m)]
  use w = slack.watch(inbox, on_message = incoming)
  for t in tickets key t.id { Triage(t) }
}
component Triage(t: Ticket) {
  instant name = Classify(t)
  state closed: Bool = false
  tool done(_: Summary) = closed <- true
  when not closed { Handle(name, t) => done }
}
```

### 2.1 state の変化（`for` の key が増える）

```
1  J → K  send(Support·incoming, m42)
2  遷移   tickets = [t42]。commit
3  再評価 tickets に依存する宣言 = for の site だけ
4  差分   + Support·(Triage,t42)·name      instant（tool call）
          + Support·(Triage,t42)·closed    state
          Handle は name に依存し name が未充足なので宣言は存在しない
5  発行   init(Support·(Triage,t42)·name, {t}, k)      依存順（親から）
6  J → K  send(k, "sales")
7  遷移   name = "sales"。commit。Support·(Triage,t42)·name のノードを dispose
8  再評価 name に依存する宣言 = when の中の Handle
9  発行   init(Support·(Triage,t42)·Handle, {name, t}, cont)
```

要素が消えるときは逆順: 接頭辞 `(Triage,t42)` 配下の全 address が消え、依存の葉から dispose し、↑ を待って親へ進む。
走行中の Handle は dispose（cancel）される。

### 2.2 `when` の反転

`done` が発火して `closed = true` になると、`when` 配下の address（`…·Handle`）が消える。`when` は接頭辞を作らないので、
再び false になれば同じ address で init される（§1.5）。

### 2.3 `use` の args の変化

`use channel = slack.channel(spec.name)` の `spec.name` が親の props で変わったとき:

```
name が updatable       → update(Team·channel, {name})。出力が変われば J → K update(cont, x') で依存先が再評価
name が updatable でない → 継続配下を全て dispose（↑ 待ち）→ dispose(Team·channel) → init(Team·channel, 新 args)
```

replace は継続全体（`use` より後の宣言すべて）を巻き込む。terraform の ForceNew の cascade と同じで、plan がその範囲を示す。

判定: 困らない。発行順は「init は親から子へ、dispose は子から親へ、同じ address では disposed を待ってから init」の 3 規則で決まる。

## 3. patch の 6 シナリオ

plan の表示形式は terraform に倣う: `~` update、`-/+` replace、`!` reset、`→` migrate、`≡` keep。

### (a) state の型が互換

`state closed: Bool` を `state closed: Bool = false` のまま、`Handle` の引数を 1 つ増やした。

```
≡ Support·(Triage,t42)·closed          keep
~ Support·(Triage,t42)·Handle          update args (+ deadline)     kind Handle: deadline updatable
```

apply 後: 走行中の Handle に update が届く。

### (b) 非互換で migration あり

`state closed: Bool` → `state step: Open | Closed`。

```
migration { component Triage { state old => { step: if old.closed then Closed else Open } } }
```

```
→ Support·(Triage,*)·{closed → step}   migrate (2 instances)
```

migration の左辺は body の state 全体の record。1 つの state を移すだけでも record で書く。

### (c) 非互換で migration なし → reset

```
! Support·(Triage,t42)·{step}          reset to init (Open)         no migration for Triage
  + Support·(Triage,t42)·Handle        init                         when not closed becomes true
```

reset 後の render が plan に出るので、「`when` が反転して Handle が再宣言される」が apply 前に見える。
Handle の address は以前 init されたことがあるので §1.5 の注記が付く。

reset の単位が body の state 全体であることの確認: 同じ body の `pending` と `turn` のような不変条件は両方まとめて初期値に
戻るので壊れない。同じ body で走行中の tool の locals は別 address なので reset されない。tool が完了して sync tool が
走るとき、reset 後の state に対して全域関数として処理される。

判定: 単位は正しい。

### (d) 走行中 tool の label

```
tool Handle(name, t) ~> Summary {
  let draft  = await Draft(t)          label draft
  let review = await Review(draft)     label review
  return finalize(draft, review)
}
```

新定義で `review` の前に `let z = await Lint(draft)` を挿入した場合:

```
走行中 Handle at draft {}                → 互換。新定義で続行。次は Lint
走行中 Handle at review { draft }        → 新 review は { draft, z } を要求。非互換
   migration があれば:  at review { draft } => review { draft, z = none }
   無ければ:            reset。最初の label からやり直す
```

やり直しのとき、sub-call の address（`…·Handle·draft·Draft`）は同じなので host には同じ id で init が届く。
Draft が結果を id で記憶していれば再実行せずに返す。これは v0.1 の replay を葉の側で行っているのと同じ。

判定: 変更が要る。**tool body 内のループは各反復を address に含めなければならない**。`for` や `loop` の反復ごとに
sub-call の address が同じになると、2 回目の反復の init が 1 回目と同じ id になり、葉がそれを再取得として扱ってしまう。
反復の key（`for x in xs key …`）を label に含める規則を spec に入れる。

### (e) `use` を 1 つ抜く

`use memory = store.namespace(…)` を Team から削除し、他は変えない。

```
- Support·(Team,"sales")·memory        dispose
≡ Support·(Team,"sales")·channel       keep (DAG edge removed)
```

`memory` に依存していた宣言があれば型検査で落ちる。無ければ辺が消えるだけ。

### (f) component の改名

`Triage` → `Ticket`。既定では別 address なので全 instance が replace になる。

```
migration { moved Support·(Triage,*) => Support·(Ticket,*) }
```

```
≡ Support·(Ticket,t42)·step            keep (moved from (Triage,t42))
```

host には何も届かない。id は address なので、**moved は host の id も変える**。host の db は id をキーにしているため、
runtime が `rename(old, new)` を送るか、id を address ではなく runtime が振る不透明な値にする必要がある。

判定: 変更が要る。protocol に `rename(old, new)` を足すか、外部に渡す id を address から分離する（address → id の対応表を runtime が持つ）。
後者の方が address の変更が host に漏れず、plan の可読性（address）と host の安定性（id）を両立できる。

## 4. 再起動

SoT:

```
Defs                       現在の版
address ↦ State            state、instant の値、tool の (label, locals)
address ↦ 外部の出力         継続 init(cont, x) の x。継続の render に必要
id ↦ 送信ログ（seq, ack）    再送と「以前 init されたか」の判定
```

手順:

```
1  root から再 render。各 address の State をはめ込む
2  外部の出力が保存されている継続は、その出力で render を続ける
3  宣言集合と送信ログを比べる: init 済み ack 済み → 何もしない。未 ack → 再送。宣言に無いのに init 済み → dispose
4  走行中の tool は (label, locals) から続行。待っている sub-call は宣言として再現され、3 の判定に乗る
5  host は自分で復帰し、未 ack を (id, seq) で除去する
```

spec-base の SoT には「外部の出力」が無い。無いと、再起動後に全ての継続が外部の再 init(cont, x) を待つことになり、
host も出力を保持して再送しなければならない。

判定: 変更が要る。**継続の入力（外部の出力 x）を runtime が保存する**。x は Data と Sink の address だけなので保存できる。
これは復帰用の handle ではなく、継続の引数の cache。

「宣言から導出できるものを保存しない」で困るケース: Pool、DAG、宣言木は導出できる。困るのは id の履歴（§1.5 の注記、
dedup）だけで、これは送信ログにある。

## 5. Pool の層化

巡回の例:

```
component Cluster(n: Int) {
  pool workers: Pool<Worker>
  Seed(workers.admit)
  for w in workers key w.id { Spawn(w, workers.admit) }     読み workers → Spawn → member workers.admit
}
```

render 依存グラフ: `pool p` を頂点、「p を読む宣言（`for … in p`、p に依存する `when` の条件）の配下（component 呼び出しを
透過して）に `member q.admit` がある」を辺 p → q とする。非巡回なら層化できる。

Admit が引数として渡るので、どの pool への member かを辿るには、`Admit<B>` の引数がどの `pool` 宣言に由来するかの流れが要る。
最小の規則は「同じ要素型 B の Admit は同じ pool とみなす」保守的近似。誤検出は要素型を分けることで回避できる。

層化されていれば render は 1 パスで終わる: pool を位相順に並べ、p を読む宣言は p への member を持つ宣言の後に評価する。
巡回的な成長（Spawn が次の Spawn を生む）は、sync tool を挟んで State に写し、次の遷移で宣言する形に書き直す。

判定: 困らない（未決のまま）。規則の候補は上のとおり。

## 6. 観測性

出すべきもの:

```
address 木     Support · (Team,"sales") · channel          可読。key が Data なのでそのまま表示できる
依存 DAG       channel ← w ← …                            ↑ の順序と replace の範囲
ノード状態     init 中 / 稼働 / dispose 中、外部の出力、instant の値
tool          現在の label と locals
版            Defs の版。patch 中は plan
送信ログ       id ごとの未 ack
```

trace は protocol のメッセージ列そのもの（init / update / dispose / disposed / send）に遷移（sync tool の発火）を挟んだもの。
v0.1 の run_events に相当するが、address が構造を持つので階層表示ができる。

判定: 困らない。

## 7. テストとモック

`Support(slack: Slack, …)` の `Slack` は provider handle で、component 構築子（`channel`、`watch`）を持つ。fake は
同じ export を持つ Katari component で書ける。

```
component FakeSlack() {
  state posted: List<(Text, Text)> = []
  export tool channel(name: Text) = component {
    tool send(m: Text) = posted <- posted ++ [(name, m)]
    export send = port(send)
    export id = name
  }
  export tool watch(ch, on_message) = component { export inject = on_message }
}
```

render は純粋なので、`render(Defs, State)` の結果（address 集合と args）を snapshot として比較できる。イベントは
`send(address, value)` で注入し、遷移後の State と render を比べる。

判定: 困らない。ただし kind の静的宣言（updatable、replace: forbidden）は fake にも要るので、kind の interface に含める。

## 8. 性能

- 再評価の範囲は静的な依存で決まるので、signal 1 つの変化で再評価されるのは依存する宣言だけ。問題ない
- `for x in p key f(x)` の key が要素の内容に依存すると、内容の変化で dispose / init になる。意図どおり
- **instant の args に集約が入ると、無関係な変化で再実行される。** `instant name = Classify(t, names(teams))` は
  team が 1 つ増えるたびに再分類する。AI 呼び出しでは費用と結果の揺れが問題になる

判定: 仕様に影響する。`instant` の再実行規則を明示する必要がある。選択肢は「args が変われば再実行（derivation として一貫）」と
「address で memo し、key を変えない限り再実行しない」。前者を既定にするなら、plan / trace に「args の変化で再実行」が出るので
気づける。後者は React の useMemo の deps を明示するのと同じで、`instant x = T(args) key k` の形になる。

## 9. plan が外部の出力に依存する render をどう扱うか

plan は render を commit なしで実行する。既存ノードの出力は SoT にある（§4）。新しく init されるノードの出力は無いので、
その継続配下は「apply 後に確定」として plan に出る。

```
+ Support·(Team,"dev")·channel         init
  … Support·(Team,"dev")·{channel の継続}   known after apply
```

判定: 困らない。terraform と同じ表示になる。

## 10. まとめ

困らなかったもの: reconcile の発行順、`when` の反転と id の再利用、reset の単位、migration の記述、Pool の層化（規則候補）、
観測性、テスト、plan の未知部分。

変更が要るもの: tool の結果に Fault を含める、ループ反復を address に含める、moved と host の id の分離、継続の入力の保存、
instant の再実行規則の明示。
