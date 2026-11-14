---
title: usage 評価 v3 — runtime、protocol、永続化、plan、観測性
description: spec-base v3（actor + React + Kotlin coroutines + terraform）の規則で、外部 component・run の実行モデル・reconcile・永続化・patch・channel の寿命を実際に書き、仕様の穴と提案を挙げる
---

対象は `../2026-10-02-spec-base-v3.md`。各節は v3 の規則のまま書き、末尾に判定（困らない / 変更が要る）を置く。
提案は末尾に番号付きで集約し、本文では `[P n]` で参照する。記法: `K→J` は Katari→外部、`J→K` は外部→Katari。

## 1. 外部 component 3 種

host の入口と出口。v2 と同じで、`event` の行き先だけが変わる。

```ts
interface Host {
  init(id: Id, args: Data, cont: Id): void       // 入口
  update(id: Id, args: Data): void
  dispose(id: Id): void
  emit: {
    init(cont: Id, output: Data): void           // 出口。export の召喚
    update(cont: Id, output: Data): void         // export の更新
    event(id: Id, value: Data): void             // runtime がこの id に紐づく channel の buffer に積む
    disposed(id: Id): void
  }
}
```

### 1.1 resource: `discord.channel`

```ts
kinds["discord.channel"] = {
  updatable: ["topic"],
  tools: { send: { params: ["text"], result: "MessageId" } },      // export される tool の signature
  async init(id, args, cont) {
    let st = await db.get(id) ?? { channelId: await discord.findOrCreate(args.name) }
    await db.put(id, st)
    emit.init(cont, { id: st.channelId })                             // send は runtime が tool 値として export に足す
  },
  async call(id, "send", { text }) { return await discord.post((await db.get(id)).channelId, text) },
  async dispose(id) { emit.disposed(id) },
}
```

`ch.send(text)` は tool 値で、run が `await ch.send(answer)` すると runtime が tool call ノード（address = run の位置）を宣言し、
host の `call(id, "send", args)` を呼ぶ。結果は `event(callId, Outcome)` 1 回。host が export する tool は kind の `tools` に静的に書く。

### 1.2 event 源: `discord.messages`

```ts
kinds["discord.messages"] = {
  events: "Message",                                  // 型。runtime が events: ReceiveChannel<Message> を export に足す
  async init(id, args, cont) {
    const cursor = (await db.get(id))?.cursor
    const sub = discord.subscribe(args.channel.id, cursor, async (m) => {
      await emit.event(id, m)                         // ack が返るまで resolve しない（runtime が buffer に永続化してから ack）
      await db.put(id, { cursor: m.seq })
    })
    emit.init(cont, {})
  },
  async dispose(id) { sub.close(); emit.disposed(id) },
}
```

**buffer を持つのは runtime。** host は `event` を送り、runtime が `msgs·events` という address の channel ノードに積んで永続化し、ack を返す。
host は ack を見てから cursor を進めるので、落ちている間の message は再送され、(id, seq) で重複除去される。
spec-base §4 の「外部の event 源は ReceiveChannel を export する」は、正確には「kind が `events: T` を宣言し、runtime が channel を
materialize する」。host が channel を作ることはできない（channel は Katari の stdlib component）。`[P 1]`

### 1.3 tool: `http.get`

```ts
kinds["http.get"] = {
  on_restart: "retry",
  async init(id, args, _cont) {
    await db.put(id, { started: true })
    const r = await fetch(args.url)
    emit.event(id, { Ok: { status: r.status, body: await r.text() } })
    await db.put(id, { done: true })
  },
  async dispose(id) { abort(id); emit.disposed(id) },
}
```

Katari 側の時系列（`let r = await http.get(url)` が run の中にある）:

```
transition   run が label r に到達。tool call ノード Bot·run·r を宣言。frame を (r, locals) で永続化
K→J          init(Bot·run·r, {url}, cont = _)
J→K          event(Bot·run·r, Ok(…))                 runtime が frame の待ちを解く
transition   run が r の次の await まで進む。書き込みを commit。render
K→J          dispose(Bot·run·r)                      完了した tool call は frame が進んだ時点で宣言から消える
J→K          disposed(Bot·run·r)
```

tool call は run の子ノードで、address は run の位置（`let` の名前）。構造化並行性の「await 中の tool は scope の子」が address にそのまま出る。

判定: 変更が要る（`[P 1]` buffer の所有者と kind の `events` 宣言を明記）。

## 2. run の実行モデル

```
transition ::= 1 つの run の sync 区間（resume から次の await まで）
             | 外部の到着の処理（event を buffer に積む、tool の結果で frame の待ちを解く、export の update）
runtime     : transition を直列化する。transition の後に render（reconcile）。render は init / update / dispose を発行する
```

1 つの component の run と子の run は、await 境界でだけ交互に走る。区間の途中で割り込まれることは無い。

順序保証:

| 範囲 | 保証 |
|---|---|
| 1 つの run | program order |
| 1 つの channel | FIFO。`receive` は積まれた順 |
| 1 つの外部 id | 連番順 |
| 異なる run の間 | 直列化されるが順序は決めない |

render を跨ぐ順序: run が `s <- v` して await に入ると、その transition で commit → render → `when s is …` の枝が init / dispose される。
次に同じ run が resume するときには、render は終わっている（render は transition の一部で、次の transition の前に完了する）。
run から見ると「await から戻ったとき、自分の書き込みは構造に反映済み」で、読者の期待どおり。

### 2.1 自分の state を待つ deadlock

```
run { s <- 1; await (s == 2) }        s を書けるのはこの run だけなので、永遠に待つ
```

`await sig` の sig が自分の state だけに依存するなら静的エラーにできる（依存は静的）。`[P 2]`

### 2.2 run と自分の宣言の消滅

run は自分の component の state を書き、それで自分の `when` 枝が消えることはあるが、自分の宣言（親が持つ）は消せない。
子の run は親の render で cancel されうる。cancel は await 境界でだけ効く（区間は原子的）。cancel された区間の書き込みは commit 済みなので、
「途中まで書いた」は起きない。

判定: 困らない。`[P 2]` は静的検査の追加。

## 3. reconcile の 1 ステップ

Bot B（spec-base §9-B）で `users` に u が増える transition を追う。

```
1  transition   run が `users <- users ∪ {u}` の後 `await inboxes.send(u, m)` で停止。commit
2  再評価       users に依存する宣言 = for の site
3  差分         + Bot·(conv,u)·history  state
                + Bot·(conv,u)·run      run（frame = 先頭）
                conv の args: inboxes.for(u) は inboxes の export で揃っている
4  発行         init は親から子へ。state → run の順（run は state に依存する）
5  transition   Bot の run が resume（send が完了）。同時に conv の run も resume 可能になるが、直列化される
```

要素が消えるとき: `(conv,u)` 配下を依存の逆順で ↓。run → その子（tool call、with の resource）→ state。run の cancel は
await 境界で効くので、↑ は run が次の await に居るときに完了する。区間の途中なら区間の終わりまで待つ。

### 3.1 body の `use` と run の `with`

| | body の `use r = kind(args)` | run の `with r = kind(args) { … }` |
|---|---|---|
| 作る主体 | render | run が到達したとき |
| address | body の label | run の位置（label）。loop の中なら `· 反復 key` |
| args の変化 | update / replace（kind の updatable） | 追従しない（値で呼んだ。変えたければブロックを抜けて入り直す） |
| 寿命 | 宣言が続く限り | ブロックの間。run の cancel で cascade |
| render との関係 | 宣言の一部。plan に出る | run の状態の一部。plan には「走行中の run が持つ resource」として出る |

`with` の resource は run の frame に属するので、SoT 上は「run の位置と locals」の中に address として現れる（§4）。
2 つの形があるのは、構造（render）と過程（run）の違いそのもので、読者に説明できる。

判定: 困らない。

## 4. 永続化と再起動

SoT:

```
Defs                           現在の版
address ↦ state                body の state
address ↦ frame                run の (label, locals, 保持している子ノードの address 集合)
address ↦ buffer               channel の未消費 item（Data）と消費カーソル
address ↦ 継続の入力            外部の export（init(cont, x) の x）
id ↦ 送信ログ                  連番、ack
```

手順:

```
1  root から再 render。state と継続の入力をはめ込む。body の宣言が復元される
2  各 run の frame を復元。frame が保持する子ノード（tool call、with の resource）は宣言として再現される
3  宣言集合と送信ログを比べる。init 済み ack 済み → 何もしない。未 ack → 再送。宣言に無いのに init 済み → dispose
4  channel の buffer を復元。receive で待っていた run は、buffer が空でなければ次の transition で resume
5  外部は自分で復帰し、未 ack を (id, seq) で除去する
```

### 4.1 locals に handle が含まれる場合

locals の handle は全て address（channel、with の resource、tool 値 = 定義名 + 引数）。復元は address の参照の復元で、値のコピーではない。

- channel の handle: channel ノードは body の `use` か外部 event 源の materialize で復元される。frame が参照する address が存在することは、
  frame の持ち主の宣言が存在することと、handle が下にしか流れないことから保証される
- with の resource: frame の「保持している子ノード」に含まれる。手順 2 で宣言として再現され、手順 3 で送信ログと照合される。
  host は id で自分の状態を復帰する
- tool 値: 定義名 + Data + handle。定義名は現在の版で解決される（単一版）

### 4.2 receive の原子性

`let m = await inbox.receive()` の pop は、run が resume する transition の一部。pop → 区間の実行 → commit が 1 transition なので、
途中で runtime が落ちれば pop ごと巻き戻る。Katari 内の配送は exactly-once。区間内で始めた tool call は宣言（address で冪等）なので、
再実行しても葉には同じ id で init が届く。

判定: 困らない。SoT に「frame が保持する子ノードの address 集合」が要ることを明記する。`[P 3]`

## 5. patch

### 5.1 走行中の run の互換判定

```
component Onboard(user: User, mail: Mail, human: Human) {
  run {
    await mail.send(welcome(user))                                 label: sent（束縛が無い。§5.3）
    let answer = await human.ask(user.manager, question(user))     label: answer
    await mail.send(summary(user, answer))                         label: done
  }
}
frame v1 = sent {} | answer {} | done { answer: Answer }
```

v2 で `answer` の前に `let team = await hr.lookup(user)` を挿入し、質問に team を含める:

```
frame v2 = sent {} | team {} | answer { team: Team } | done { team, answer }
```

| 走行中の位置 | 判定 |
|---|---|
| `sent {}` | 互換。新定義で続行。次は team |
| `answer {}` | v2 の answer は team を要求。非互換 |

plan:

```
~ Onboard·(User,u1)·run        at answer {}      INCOMPATIBLE: new `answer` requires { team: Team }
    migrations available:  at answer {} => team {}                 （質問を取り下げて team から）
                           at answer {} => answer { team = … }     （質問を維持）
    without migration:     restart from `sent`  (mail.send is replace: forbidden → BLOCKED)
```

`human.ask` の呼び出しは frame の子ノード（address `…·run·answer·ask`）なので、1 つ目の migration では dispose が届き、UI から質問が消える。
plan は「この migration で dispose される子ノード」を列挙できる（frame の子ノード集合が SoT にある）。

### 5.2 channel の buffer に古い型の item がある場合

`channel<Message>` の `Message` に field を足した場合、buffer の item は旧型。選択肢:

```
migration { channel Bot·inbox { item old => { old with thread: none } } }     変換
migration { channel Bot·inbox { drop } }                                      捨てる（明示）
```

migration が無ければ plan が BLOCKED にする（黙って捨てない）。channel の item は Data なので変換は書ける。`[P 4]`

### 5.3 束縛の無い await の label

`await mail.send(…)` は束縛名が無い。label を文の位置にすると、文を 1 つ挿入しただけで後続の label が全部ずれる（第 1 版で位置ベースを捨てた理由と同じ）。
規則の候補:

```
束縛の無い await の label = 呼び出した tool の名前 · 同じ run 内の出現番号      send·1、send·2
```

出現番号は tool 名ごとなので、別の tool を挿入してもずれない。同じ tool を途中に挿入するとずれる。
確実にしたければ `let _sent = await …` と名前を付ける。plan が label を表示するので、ずれは見える。`[P 5]`

判定: 変更が要る（`[P 4]` `[P 5]`）。

## 6. 層化と channel の巡回

Pool の層化は v3 で変わらない（`member` と `for` の render 依存の話で、run は関係しない）。

channel の巡回: A が B の channel に送り、B が A の channel に送る。

```
component Team() {
  use ca = channel<Note>()
  use cb = channel<Note>()
  use a = Analyst(inbox = ca.receive, peer = cb.send)
  use b = Critic(inbox = cb.receive, peer = ca.send)
}
```

- runtime 上は問題ない。send は buffer に積むだけで、render の依存を作らない。ping-pong が止まらないのは論理的な無限ループで、`run { loop }` と同じ扱い
- **子の export を互いに渡す形は書けない。** `use a = Analyst(peer = b.inbox)` と `use b = Critic(peer = a.inbox)` は依存の循環で静的エラー。
  channel を親が作って両方に配る（上の形）。これは「mailbox は親が作る」という actor の作法と一致する。指針に書く

判定: 困らない。

## 7. 観測性

```
address 木          Bot · (conv, u) · run                 可読
state               各 address の値
run                 現在の label、locals、保持している子ノード、await の対象（tool / channel / signal）、待ち時間
channel             buffer 長、最古の item の滞留時間、receive で待っている run
依存 DAG            ↑ の順序、replace の範囲
版                  Defs の版。patch 中は plan
送信ログ            id ごとの未 ack
```

trace は protocol のメッセージ列に transition（どの run のどの区間）を挟んだもの。run の label があるので「今どこで何を待っているか」が
v0.1 の escalation 一覧に相当する表示になる（人間待ちは `await human.ask` の位置で見える）。

判定: 困らない。

## 8. テストとモック

fake kind は Katari の component で書ける。event 源は channel を export するだけ。

```
component FakeDiscord() {
  use feed = channel<Message>()
  state posted: List<Text> = []
  export messages = component (ch) { export receive = feed.receive }
  export channel  = component (name) { export send = Post(self, _) ; export id = name }
  export inject   = feed.send
  …
}
```

`posted` を書くには fake の run が要る（state は run だけが書く）: `loop { let t = await outbox.receive(); posted <- posted ++ [t] }`。
`Post` は outbox に送る tool。fake の中にも actor の形が要るのは一貫しているが、v2 より 3 行長い。

テストの形: transition が直列化され render が純粋なので、`inject(m)` → quiescent まで進める → state と宣言集合を比べる、が決定的にできる。
`katari test` は「channel に item を積み、runtime を quiescent まで回し、snapshot を比べる」の 3 操作で足りる。

判定: 困らない。

## 9. 性能

- 1 件の event = 1 transition + 1 render。render は静的依存で範囲が決まるので、state が変わらなければ何も再評価しない。
  event を buffer に積むだけの transition は state を変えないので render は空
- `receive_all` が batching。推論のような重い処理は batch 単位で走る
- 大きな buffer: list の書き換えでなく append-only log + 消費カーソルで永続化する。実装の話で意味論には影響しない
- 背圧: `send` は容量があれば suspend する。外部の event 源は suspend できないので、runtime が ack を遅らせる（host は cursor を進めない）。
  容量は channel の引数（既定は無制限で、buffer 長を trace に出す）。`[P 6]`

判定: 困らない（`[P 6]` は定義の追加）。

## 10. Sink の問題が channel で再発するか

| v0.1 の問題 | channel での扱い |
|---|---|
| 寿命を越えて情報が逃げる | item は Data。channel ノードは所有者（宣言した component）のもので、送り手が消えても item は所有者の資産。所有者が決めて消費する。逃げていない |
| 受け手（port）が消えた後の送信 | handle は下にしか流れず、channel の宣言に依存する宣言は channel より先に dispose される（DAG）。dangling な send handle は存在しない |
| 古い結果が後から届く | tool の結果は frame の待ちを解くだけ。frame が cancel されていれば結果の行き先が無く捨てられる。channel の item は順序どおり run が読むので、「古い n の TurnDone」のような取り違えが構造的に起きない |
| 送り手が cancel された後に item が残る | 送信は commit 済みの事実。残ってよい。受け手が「もう要らない」と判断するのは受け手の loop |
| 受け手が消えた後の buffer | channel ごと dispose される。未消費 item は消える。残したければ channel を上に置く（所有の規則そのもの） |

v0.1 の Sink の問題は「port が送り手の寿命と無関係に存在し、配送中の情報に所有者が居ない」ことから来ていた。channel は所有者を持つ
ノードで、item は所有者の state の一部なので、同じ問題は起きない。

判定: 困らない。

## 11. まとめ

困らなかったもの: run の実行モデルと順序保証、reconcile と `with`、永続化と再起動、層化と channel の巡回、観測性、テスト、Sink の問題の再発。

変更が要るもの: event 源の buffer の所有者（kind の `events` 宣言 + runtime の materialize）、束縛の無い await の label、channel の item の migration、
背圧の定義、frame の子ノード集合を SoT に含めること、自分の state を待つ await の静的検査。

## 提案

1. **must** 外部の event 源は channel を作れない。kind が `events: T` を宣言し、runtime が `events: ReceiveChannel<T>` を export に materialize する。
   buffer は runtime が持ち、`event` の ack は永続化後。host は ack を見て cursor を進める
2. **should** `await sig` の sig が自分の state だけに依存するなら静的エラー（永遠に待つ）
3. **must** SoT の frame に「保持している子ノードの address 集合」（tool call、with の resource）を含める。無いと再起動後に run の子を再現できない
4. **must** channel の buffer の item の型が変わる patch は migration（`channel addr { item old => new }` か `drop`）を要求し、無ければ BLOCKED。黙って捨てない
5. **should** 束縛の無い await の label = tool 名 · run 内の出現番号。位置ベースにしない。plan が label を表示する
6. **should** channel の容量と背圧の定義。`send` は容量超過で suspend。外部の event 源には ack の遅延で伝える。既定は無制限で buffer 長を trace に出す
7. **nice** 子の export を互いに渡す形は依存の循環になる。mailbox は親が channel を作って配る、を指針に書く

## 仕様のまま書けたが違和感がある点

- fake kind でも state を書くのに run が要る。`posted <- …` のためだけに loop を書くのは 3 行長い
- body の `use` と run の `with` で、同じ resource の args の追従が変わる（前者は update、後者は値）。構造と過程の違いとして説明はできるが、初見では引っかかる
- 完了した tool call が dispose → disposed の往復を外部に送る。tool の葉には冗長（v2 と同じ）
- run の cancel が await 境界でしか効かない。区間が長い純粋計算（大きな list の畳み込み）は止められない。区間の全域性の規則で有限ではあるが、上限は無い

## 未決の問い

- event 源の resource が replace されたとき（args の変化で dispose → init）、runtime が materialize した channel の buffer を残すか捨てるか。address は同じなので残せる
- 1 つの ReceiveChannel を複数の run が receive したときの意味（competing consumers か、禁止か）。`channels.for(k)` は単一消費者を想定している
- `await sig` の sig が Pool の集約（`count(p)`）のとき、Pool の層化と run の待ちがどう絡むか
- 区間の実行時間の上限（全域だが有限とは限らない）を runtime で切るか
