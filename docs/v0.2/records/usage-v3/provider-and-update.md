---
title: v3 評価 — provider と 2 段階 update
description: 外部 provider（JS）と runtime の側から、update(id, args, uid) / updated(uid) の実装可能性、失敗・再起動・patch・連打との組み合わせ、kind の静的宣言の Katari 表現を確かめる
---

対象は `../2026-10-02-spec.md` §1.6、§5、§1.3。host（JS）の擬似コードと Katari 側の時系列で書き、各節末に判定を置く。
提案は末尾に集約し、本文では `[P n]` で参照する。記法: `K→J` runtime→host、`J→K` host→runtime。

## 0. runtime が host に求める interface

spec の protocol をそのまま host の入口と出口にすると次になる。

```ts
interface Host {                                        // 入口（runtime → host）
  init(id: Id, args: Args, cont: Id): void
  update(id: Id, args: Args, uid: Uid): void            // 新しい引数の提示
  updated(cont: Id, uid: Uid): void                     // host が継続に流した update が、継続の配下で乗り換え終わった
  dispose(id: Id): void
  eventAck(id: Id, seq: number): void                   // event を永続化した
}
interface Runtime {                                     // 出口（host → runtime）
  init(cont: Id, output: Output): void
  update(cont: Id, output: Output, uid: Uid): void      // 出力が変わった。継続に流してほしい
  updated(id: Id, uid: Uid): void                       // この id は新しい引数に乗り換え、古い引数の要素を参照しなくなった
  failed(id: Id, uid: Uid | null, error: Error): void   // init か update に失敗した（§4）
  event(id: Id, value: Data): void
  disposed(id: Id): void
}
```

`args` の中の handle は、host には **参照先の現在の出力の Data 部分** と tool 値の不透明な id として届く
（`discord.messages(ch)` の host は `args.channel.id` を読む）。spec にこの規則が無い `[P 1]`。

## 1. `discord.channel`（create-first、`name` が updatable）

```ts
kinds["discord.channel"] = {
  updatable: ["name", "topic"],
  tools: { send: { params: { text: "Text" }, result: "MessageId" } },

  async init(id, args, cont) {
    const conn = await discord.open(args.name)                 // 冪等: id をキーに既存を再取得
    await db.put(id, { cont, current: conn, pending: null })
    runtime.init(cont, { id: conn.channelId })                 // send は runtime が tools 宣言から export に足す
  },

  async update(id, args, uid) {
    const st = await db.get(id)
    if (args.name !== st.current.name) {                       // 出力が変わる更新
      const next = await discord.open(args.name)               // create-first: 先に作る
      await db.put(id, { ...st, pending: { uid, conn: next } })
      runtime.update(st.cont, { id: next.channelId }, uid)     // 継続に流し、updated(cont, uid) を待つ（§updated）
    } else {                                                   // topic だけ。出力は変わらない
      await discord.setTopic(st.current, args.topic)
      runtime.updated(id, uid)
    }
  },

  async updated(cont, uid) {                                   // 継続の配下が乗り換え終わった
    const id = await db.ownerOf(cont); const st = await db.get(id)
    if (st.pending?.uid !== uid) return                        // 古い uid（§7）
    await discord.close(st.current)                            // ここで初めて古い接続を閉じる
    await db.put(id, { cont, current: st.pending.conn, pending: null })
    runtime.updated(id, uid)                                   // 親（Bot の宣言 ch）に報告
  },

  async call(id, "send", { text }) { return discord.post((await db.get(id)).current, text) },
  async dispose(id) { const st = await db.get(id); await discord.close(st.current); if (st.pending) await discord.close(st.pending.conn); runtime.disposed(id) },
}
```

Katari 側の時系列（spec §1.6 の例）:

```
K→J  update(ch, { name: new }, u1)
J    新しい接続を開く
J→K  update(cont_ch, { id: C02 }, u1)                 継続 = msgs、conv、Bot の run
K    msgs に update(msgs, { channel: { id: C02 } }, u1) → J→K updated(msgs, u1)
K    conv に update(conv, { ch: { id: C02 } }, u1) → conv の配下 … → updated(conv, u1)
K    Bot の run は phase の終わりで乗り換え
K→J  updated(cont_ch, u1)                             揃った
J    古い接続を閉じる
J→K  updated(ch, u1)
```

`send` の呼び出しは tool call ノードで、args に `ch` の要素を束縛している。phase の中で始まった call は旧接続で完走する
（host の `call` は `current` を読むので、`updated(cont)` が来るまで `current` は旧のまま）。整合する。

判定: 実装できる。host が待つのは「自分が流した update の updated」だけで、継続の中身は知らなくてよい。

## 2. `discord.messages`（event 源、`channel` が updatable）

```ts
kinds["discord.messages"] = {
  updatable: ["channel"],
  events: "Message",

  async init(id, args, cont) {
    const st = { channelId: args.channel.id, cursor: (await db.get(id))?.cursor ?? "now" }
    st.sub = discord.subscribe(st.channelId, st.cursor, m => deliver(id, m))
    await db.put(id, st); runtime.init(cont, {})
  },

  async update(id, args, uid) {
    const st = await db.get(id)
    const next = discord.subscribe(args.channel.id, "now", m => deliver(id, m))    // 先に新しい購読
    st.sub.close()                                                                 // 同じ transition で旧を閉じる
    await db.put(id, { channelId: args.channel.id, cursor: "now", sub: next })
    runtime.updated(id, uid)                                                       // 出力（{}）は変わらないので継続には流さない
  },
  async dispose(id) { (await db.get(id)).sub.close(); runtime.disposed(id) },
}
async function deliver(id, m) { await runtime.event(id, m) /* eventAck まで resolve しない */; await db.put(id, { cursor: m.seq }) }
```

- buffer は runtime 側（`msgs.events` の channel ノード）。旧 channel の message と新 channel の message は届いた順に同じ buffer に並ぶ。
  消費者（Bot の run）は区別しないし、する必要も無い
- 張り直しの間に旧 channel に届いた message は、旧購読を閉じる前に `deliver` 済みなら buffer にある。閉じた後のものは拾わない（切り替えの意味として正しい）
- cursor は channel ごと。更新で `"now"` に戻す。「新 channel の過去分も欲しい」は kind の引数（`since`）で表す

判定: 実装できる。出力が変わらない update は `updated` を即返しでよい、を spec に書く `[P 2]`。

## 3. destroy-first の kind（固定名 channel）

`destroy_first` の kind に名前の変更が来たとき、runtime は update ではなく dispose → init を行う。問題は **継続**。

- 継続の宣言（msgs、conv）は旧要素を束縛している。旧要素が消えるので、これらは update ではなく dispose → init になる（要素が無い間、存在できない）
- Bot の run は `ch` を読むとき、要素が無ければ待つ（§2.1）。phase の中で旧 ch を使っていれば、runtime は phase の終わりまで dispose を遅らせる

```
K    Bot の run が phase を抜けるまで待つ（phase の中なら）
K    継続の宣言を依存の逆順に dispose: conv の配下 → conv → msgs
K→J  dispose(ch)  →  J→K disposed(ch)
K→J  init(ch, { name: new }, cont_ch)  →  J→K init(cont_ch, { id: C03 })
K    継続の宣言を init: msgs → conv → …
K    Bot の run は次の区間から新しい ch を読む（待っていれば resume）
```

つまり destroy-first は「葉の差し替え + 継続の召喚し直し」で、update は流れない。spec §1.6 の「2 と 5 の順が逆」は正確にはこれ `[P 3]`。
継続に state を持つ子（conv の history）が消えるので、plan に出すべき作用（terraform の ForceNew cascade と同じ）。

判定: 実装できるが、create-first との差が大きい。既定を create-first にするのは正しい。

## 4. update の失敗

`discord.open(args.name)` が失敗したとき。

```ts
async update(id, args, uid) {
  try { … } catch (e) { runtime.failed(id, uid, describe(e)) }     // 旧要素はそのまま。何も閉じていない
}
```

- create-first なので旧要素は無傷。runtime は pool を旧要素のまま保ち、ノードの `status` を `Faulted(UpdateFailed(e))` にする。
  親の `updated` は返さない（親も Faulted の連鎖ではなく、「pending のまま」として plan / trace に出る）
- 望ましい引数と実際の要素がずれた状態（drift）。再試行は、引数がもう一度変わったとき、または明示の再 apply。runtime が勝手に retry しない
- `init` の失敗も同じ `failed(id, null, e)`。継続は召喚されず、status が Faulted。spec に init / update の失敗が無い `[P 4]`
- Katari component の宣言の再評価が途中で失敗する（子の init が failed）: その子が Faulted、親の `updated` は保留。部分的に乗り換えた状態は
  「子ごとに status が違う」として見える。transition 自体は失敗しない（render は純粋。失敗は葉でしか起きない）

```
plan / trace
  ~ Bot·ch     update pending (u1): name "a" → "b"     FAILED: discord.open: 403    actual: "a"
```

判定: 変更が要る。失敗の protocol（`failed`）と drift の表示。

## 5. 再起動を跨ぐ update

SoT に要るもの:

```
address ↦ pool の要素列  [(gen, element)]            旧要素は参照者がいる間残る
edge ↦ 消費者の gen       依存辺ごとに「この消費者はどの gen まで乗り換えたか」
id ↦ 送信ログ            update(uid) の送信と ack
```

uid を **pool の世代番号（gen）** にすると、「updated 待ち」の状態が辺の gen から導出できる `[P 5]`:

- `updated(uid)` = 「この消費者の gen は uid 以上」
- 旧要素 g を解放できる = 全ての消費者の gen > g
- 再起動後: 送信ログで未 ack の update を再送。host は uid を自分の db に持ち、再送された update(uid) を「適用済みなら updated を再送」で冪等に扱う

host が落ちて復帰: `pending` を db に持っているので、`current` と `pending.conn` の両方を再取得し、runtime からの `updated(cont, uid)`（再送される）を待てる。

判定: 困らない。uid = gen にすると SoT が「辺の gen」だけになる。

## 6. patch と update の重なり

apply の瞬間に乗り換え途中の pool がある（消費者の gen が揃っていない）。

- plan は「pending update: N 件（address と gen）」を出す
- apply は待たない。apply は木全体の 1 transition で、pool の要素列と辺の gen は address に紐づく state なのでそのまま残る。apply 後も乗り換えは続く
- patch が pool の定義を変える（要素型が変わる、宣言が消える）場合は、pending を含めて replace / dispose になる。plan に出る
- migration 関数は state と frame を見るだけで、gen には触れない

判定: 困らない。plan の表示を 1 行足す。

## 7. update の連打

gen 1 の乗り換え中に gen 2 が来る。

- runtime: pool の要素列は `[(1, a), (2, b), (3, c)]` と伸びる。消費者は phase の終わりで **最新の gen に跳ぶ**（2 を飛ばしてよい）。
  要素 g の解放は「全消費者の gen > g」なので、誰も 2 を見なければ 2 は作られ次第 解放される
- host（create-first）: `pending` を 1 つにせず gen ごとに持つ。`updated(cont, g)` が来た gen より小さいものを閉じる。
  作成中（`discord.open` の await 中）に次の update が来た場合、作成を中止してよい（まだ継続に流していないので参照者はいない）
- `phase` の中の run に 2 つ溜まった場合: phase を抜けたとき最新に跳ぶ。中間の要素は run からは見えない

```ts
async update(id, args, uid) {                         // gen ごとの pending
  const next = await discord.open(args.name)
  st.pending.set(uid, next); runtime.update(st.cont, { id: next.channelId }, uid)
}
async updated(cont, uid) {
  for (const [g, conn] of st.pending) if (g < uid) { await discord.close(conn); st.pending.delete(g) }
  await discord.close(st.current); st.current = st.pending.get(uid); st.pending.delete(uid)
  runtime.updated(id, uid)
}
```

判定: uid を順序付き（gen）にすれば単純。spec に「新しい gen は古い pending を打ち切ってよい」を書く `[P 6]`。

## 8. `updated` の揃い方の計算

runtime は依存辺ごとに消費者の gen を持つ（§5）。Katari component が入力 X の gen g に乗り換えたと言えるのは:

```
X に依存する宣言が g で再評価され、その子ノード（辺の先）の gen が全て ≥ g      （子の updated）
かつ run の phase が g 以降に始まっている                                          （run の乗り換え）
```

run の phase が長いと component の gen が上がらず、親の旧要素が残る。これは意図（§1.6）で、trace に「updated 待ち: run の phase」と出す。
tool call ノード（run の中の call）は args に要素を束縛しているので辺を持ち、call が完了して frame から消えるまで旧要素を保持する。

判定: 困らない。辺の gen で全部表せる。

## 9. 外部が親になる場合（mcp.serve）

`use srv = mcp.serve(listen, tools = { search = Search(kb, _) })` で `kb` の要素が変わると、tool 値が再評価され serve の `tools` 引数が変わる。

- `update(srv, { tools: { search: <新しい tool 値の id> } }, g)`。host は次の call から新しい tool 値を使い、即 `updated(srv, g)`
- 走行中の call（`srv·(call, id)` のノード）は args に旧 `kb` を束縛しているので辺を持ち、完了するまで旧 kb は解放されない
- 外部クライアントには何も届かない（tool の名前と schema が変わらない限り）。schema が変われば serve kind が `tools/list_changed` 相当を送る。kind の仕事

判定: 困らない。

## 10. kind の静的宣言を Katari の末端 component で表す

試案を書いてみると、**Katari で書く末端 component には静的宣言がほぼ要らない** ことが分かる。

| 宣言 | 外部 kind での意味 | Katari の末端での対応 |
|---|---|---|
| `updatable: [args]` | どの引数を update で受けられるか | 全引数が pool。run が `for await` で追従すれば乗り換え、しなければ phase の終わりで乗り換え。常に update 可能 |
| `destroy_first` | 作り直しの順序 | 作り直されない（update を生き延びる）。順序を変えたければ run の中で `finally` の前に新しいものを作る |
| `interruptible: false` | 完了まで dispose を送らない | cancel は await 境界でしか効かない。区間が原子的なので「途中で止まらない」は自動。長い区間は書き手の責任 |
| `on_restart` | 開始済み未完了の葉の扱い | frame から resume。葉の契約は呼んでいる外部 tool のもの |
| `on_dispose` | delete か detach か | `finally` に書く |
| `events: T` | runtime が channel を materialize | export できない（receive 側は所有者だけ）。`to: SendChannel<T>` を引数に取って送る |
| `tools` | export する tool 値 | `export search = Search(kb, _)` |
| `replace: forbidden` | plan のブロック | patch の reset で run が最初から走ると作用が再実行される。Katari の末端にも要る（唯一残る宣言） |

```
component channel(discord: Discord, name: Text, topic: Text) {
  export state id: Option<Text> = None
  run {
    id <- Some(await discord.api.create(name))
    for await t in topic { await discord.api.setTopic(id, t) }          topic の変化に追従（updatable 相当）
  } finally {
    if id is Some(i) { await discord.api.delete(i) }                   on_dispose: delete 相当
  }
  export send = Post(discord, id, _)
}
```

`name` の変化に追従していないので、name が変わっても同じ channel のまま（Katari の末端は作り直されない）。
作り直したければ親が `for n in name key n { use ch = channel(discord, n, topic) }` と書く。これは **外部 kind の `updatable` を、呼び出し側の `for … key` で表現している** ことになり、
外部 kind にも同じ形を適用できる: `updatable` を kind に書かせず、呼び出し側が「この引数で同一性を分ける」と書く `[P 7]`。

`events` の行は非対称が残る。外部 kind は runtime が channel を作り、Katari の末端は `to:` に送る。外部 kind も `to: SendChannel<T>` を引数に取る形に揃えれば、
materialize の規則と `events` 宣言が消え、component の inbox を 1 つにする案（`receives Msg`）とも揃う `[P 8]`。

判定: 残る静的宣言は `replace: forbidden`、`interruptible`、`on_restart`、`tools` の 4 つで、どれも外部の葉の性質。Katari の末端には `replace: forbidden` だけ。

## 提案

1. **must** handle を含む args が host にどう届くかを定める: 参照先の現在の出力の Data 部分 + tool 値の不透明 id
2. **should** 出力が変わらない update は継続に流さず `updated` を即返しでよい、と書く
3. **must** destroy-first は「葉の dispose → init + 継続の召喚し直し」で、update は流れない。継続の state が消えることを plan に出す
4. **must** init / update の失敗を protocol に入れる（`failed(id, uid?, error)`）。create-first の失敗は旧要素のまま `Faulted(UpdateFailed)`、drift を plan に出す。runtime は勝手に retry しない
5. **should** uid を pool の世代番号（gen）にする。`updated(g)` = 消費者の gen ≥ g。旧要素の解放 = 全消費者の gen > g。再起動・連打・patch の全てが「辺の gen」だけで表せる
6. **should** 連打: 消費者は最新の gen に跳んでよい。host は継続に流す前の作成を中止してよく、gen ごとに pending を持つ
7. **nice** `updatable` を kind の宣言から外し、呼び出し側の `for … key` で「この引数で同一性を分ける」を表す。Katari の末端と外部 kind が同じ形になる
8. **should** 外部 event 源も `to: SendChannel<T>` を引数に取る形に揃え、runtime の materialize と `events` 宣言を消す

## 実装上の懸念

- 辺ごとの gen を runtime が持つので、依存 DAG が永続化の対象になる（これまでは導出物だった）。gen だけを address 対で持てば DAG 自体は導出のまま
- tool call ノードが旧要素を保持する期間は call の長さ。人間待ちの call が phase の外にあっても、その call の args に束縛された旧要素は call が終わるまで残る。意図どおりだが trace に出ないと分かりにくい
- host の `updated(cont, uid)` 入口は、host が継続を持つ kind（出力が変わる kind）にだけ要る。tool と event 源には要らない
- `failed` の後に同じ uid の update を再送しない規則が要る（再起動後の再送と区別するため、送信ログに failed を記録）

## 未決の問い

- create-first で新要素を作った後、継続の乗り換えが長く終わらない（phase が長い）ときに、host に「待っている」ことを伝える必要があるか（timeout は kind が決める？）
- drift（update 失敗で旧要素のまま）の再試行を誰が起こすか。引数が同じままでは再評価が起きない
- `interruptible: false` の葉を args に束縛している phase が cancel されたとき、葉の完了と phase の finally のどちらを先に待つか
