---
title: v3 評価 — 2 段階 update と phase の書き手 UX
description: 第 3 版 §1.5–1.6、§2.1、§5 の規則（pool のまま渡す、update / updated、phase、create-first）を 10 の example で追い、書き手の直感との差と規則の穴を挙げる
---

対象は `../2026-10-02-spec.md` の §1.3、§1.5、§1.6、§2.1、§5。各 example は仮想コード、update / updated の時系列、評価の順。
提案は末尾に集約し、本文では `[P n]` で参照する。記法: `→` は親→子、`←` は子→親。

## 1. 3 段のネストで最上位の ch_id が変わる

```
component Org(discord: Discord, model: Model, ch_id: Text) {
  use team = Team(discord, model, ch_id)
}
component Team(discord: Discord, model: Model, ch_id: Text) {
  use ch  = discord.channel(ch_id)
  use bot = Bot(discord, model, ch)                       ch は pool のまま渡す
}
component Bot(discord: Discord, model: Model, ch: Channel, reviewer: Human) {
  use msgs = discord.messages(ch)
  loop {
    let m = await msgs.events.receive()
    phase {
      let answer = await reviewer.ask(draft(m))            数日
      await ch.send(answer)
    }
  }
}
```

| 時点 | 出来事 |
|---|---|
| 0 | Bot の run は phase の中、`reviewer.ask` で待っている |
| 1 | Org に `update(org, { ch_id: new }, u1)`。宣言 `team` の args が変わる → `update(team, …, u1)` |
| 2 | Team の宣言 `ch` の args が変わる → `update(ch, { name: new }, u1)`。kind は create-first で新しい接続を作り、継続に `update(cont, …, u1)` |
| 3 | 継続 = `bot` → `update(bot, { ch: new }, u1)`。Bot の宣言 `msgs` の args が変わる → 購読を新しい ch に張り直し `updated(u1)` |
| 4 | Bot の run は phase の中。乗り換えは phase を抜けた境界。Bot は `updated` を返さない |
| 5 | 新しい ch に届いた message は `msgs` の buffer に溜まる（宣言は既に新しい ch） |
| 6 | 数日後、人間が答える。`ch.send(answer)` は旧 ch（phase の中）。phase を抜ける → run が乗り換え → Bot `← updated(u1)` |
| 7 | Team の継続の updated が揃う → kind は旧接続を閉じる → Team `← updated(u1)` → Org `← updated(u1)` |

評価:

- 「旧 ch は、それを使っている処理が終わるまで残る」は、書き手の期待どおり。処理の途中で返信先が変わる方が困る
- **同じ component の中で、宣言（msgs）は新しい ch、run は旧 ch、という混在が数日続く。** これは意図した設計（構造は世界に追従し、過程は今の step を旧入力で終える）だが、
  書き手は「Bot ごと切り替わる」と読みがち。混在を避ける方向（宣言も phase の終わりまで待つ）は、新しい ch への message を数日取りこぼすので採れない。
  spec は「phase は run の読みだけを固定する。宣言は固定しない」を明記する `[P 1]`
- 3 段上の Org は、3 段下の phase が終わるまで `updated` を得られない。何を待っているかが見えないと運用で困る。trace / plan に
  「update u1 pending: Bot·run phase at `reviewer.ask` (2d)」を出す `[P 2]`

## 2. phase 無しで await を跨ぐ

```
loop {
  let m = await msgs.events.receive()
  let answer = await ai.infer_text(model, prompt(m))        ← この await の間に ch が差し替わる
  await ch.send(answer)                                     ← 次の区間。新しい ch を読む
}
```

- `ch.send` は新しい ch に届く。旧 ch への送信は起きない。「旧 ch の message への返信が新 ch に出る」は、書き手が ch_id を変えた以上は妥当。驚くなら phase で囲む
- `use typing = discord.typing(ch) { … }` のブロックの中で ch が差し替わっても、ブロックは phase なので中の `ch.send` は旧 ch。spec どおり

```
loop {
  let m = await msgs.events.receive()
  let c = ch                                                ← 要素を let に束縛
  let answer = await ai.infer_text(model, prompt(m))        ← ここで差し替え。区間境界 = phase 境界なので run は乗り換え、Bot は updated を返す
  await c.send(answer)                                      ← c は解放済みの要素。Fault
}
```

- **規則の穴。** §1.6 は「runtime は frame の参照を追跡しない」とし、updated は phase 境界で返る。`let` に束縛した要素は phase を跨いで生き残り、
  親はそれを知らずに旧要素を解放する。`let c = ch` が scope にある間は phase が続く、と決めれば構造で塞がる（`use r = … { }` のブロックと同じ扱い）`[P 3]`

## 3. 要素を同一性にした子と、pool を渡した子

```
// A. pool を渡す（既定）
use conv = Conversation(ch, model)                 ch が差し替わっても conv は残る。state と run が続く

// B. 要素を同一性にする
use conv = Conversation(ch, model) key ch.id       key が要素から導かれるので、差し替えで別の instance
```

| | A | B |
|---|---|---|
| ch の差し替え | update が流れ、conv の宣言は新 ch、run は phase の終わりで乗り換え | 新 ch の conv を init、旧 ch の conv を dispose（run は cancel、finally）、その後 updated |
| state（history） | 残る | 消える |
| 向く場面 | 「この bot」が担当 channel を変える | 「この channel の記録係」のように子が要素そのものについてのもの |

- 既定は A。B は `key` で書けるので、§1.5 の「`for c in ch key … { … }`」という綴りは要らない。0 / 1 の pool に `for` を書くのは読みにくい `[P 4]`
- B で旧 conv の dispose が終わるまで updated は返らない。旧 conv の run が phase の中なら、§1 と同じく待つ

## 4. destroy-first の kind

固定名の channel（`discord.channel(name)` で name が一意）。`destroy_first` を宣言している。

```
1  update(ch, { name: new }, u1)
2  kind は先に旧接続を閉じたい。しかし継続（msgs、bot）が旧要素を参照している
3  継続に「要素が無い」を伝えなければならない。protocol に update(cont, ∅) は無い
```

- **規則の穴。** destroy-first を update で表すには「空への update」が要り、継続の宣言（msgs）は要素が無いので dispose、run の読みは待つ、
  その後 new で再 init、という 2 往復になる。これは replace（dispose → init）と同じ形なので、**destroy-first の kind は update せず replace する** と決めれば protocol は増えない。
  `destroy_first` = 「この引数の変化は replace」で、`updatable` の否定と同じ。両方の宣言は要らない `[P 5]`
- replace の間、Bot の `msgs` は dispose → init され、run の `ch` の読みは空なので待つ（§2.1）。この間に旧 channel に届いた message は失われる。固定名である以上は避けられない

## 5. update の連打

ch_id が a → b → c と短時間に変わる。

```
1  update(…, b, u1) が流れる。msgs は b に張り直し updated(u1)。Bot の run は phase の中
2  update(…, c, u2) が流れる。msgs は c に張り直し updated(u2)
3  Bot の run が phase を抜ける。読むべきは c。b は一度も読まれない
4  Bot は updated(u2) を返す。u1 は？
```

- 規則の候補: **`updated(uid)` は、それ以前の uid 全てを含意する。** 親は最新の ack より古い要素を全て解放してよい。途中の要素を飛ばしてよい `[P 6]`
- kind（create-first）は接続 a、b、c を同時に持ちうる。updated(u2) で a と b を閉じる。接続数は連打の回数で有界
- phase の中に 2 回分の update が溜まっても、乗り換えは 1 回（最新）。書き手は中間を見ない。妥当

## 6. 子が updated を返さない

- run が phase の中で永遠に待つ（人間が答えない）: 親は旧要素を解放できない。これは「使っているものは解放しない」の帰結で正しい。対処は親が子の宣言を消す（`key` を変える、`when` を偽にする）こと。
  dispose は updated を待たずに cascade する
- run が Faulted: run は phase の外なので、宣言の updated が揃えば ack される。Faulted は ack を妨げない。spec に明記 `[P 7]`
- 見せ方: plan / trace に pending な update と、それを止めている run の位置を出す（`[P 2]`）。`status` に `pending_update: Option<uid>` を足す案もあるが、trace で足りる

## 7. Data props の update

```
component Team(spec: TeamSpec, ch: Channel, model: Model) {
  use reply = Reply(ch, spec.persona, _)             tool 値。spec.persona が変われば再評価
  use agent = Agent(model, { reply = reply })
}
```

| 時点 | 出来事 |
|---|---|
| 1 | `update(team, { spec: … }, u1)`。`reply` の式が再評価され、新しい tool 値 |
| 2 | `agent` の args が変わる → `update(agent, { tools: … }, u1)`。Agent の run はターンの phase の中（`par` で tool call 中） |
| 3 | 走行中の tool call は call 時の引数（旧 persona の `reply`）で完走する |
| 4 | phase を抜けて `let ts = tools` を取り直すと新しい persona |

- 書き手の期待どおり。「AI が今している返信は旧 persona、次から新 persona」
- Data だけの update では解放すべきものが無いので、updated の待ち合わせに意味が無い。runtime は Data だけの update の ack を省略してよい（protocol 上は返す）`[P 8]`

## 8. phase の中の state 書き込み

```
loop {
  let m = await msgs.events.receive()
  phase {
    status <- Answering                      ← 次の await で commit → render
    let a = await ai.infer_text(model, prompt(m))
    await ch.send(a)
  }
  status <- Idle
}
```

phase の途中で ch の update が待っている場合:

- `status <- Answering` は phase の中の await 境界で commit され、render される。render は宣言の pool（新しい ch）と state（Answering）を見る
- run は旧 ch を読み続ける。render と run が別の ch を見るのは §1 の混在と同じで、意図どおり
- commit の順序は「state は区間ごと、要素の乗り換えは phase ごと」。混ざらない。spec の §2.2 に「phase は commit を遅らせない」を 1 行足す `[P 1]`

## 9. tool が resource を作る

```
component Studio(images: Drive, model: Model) {
  state gallery: List<ImageId> = []
  loop {
    let p = await prompts.events.receive()
    gallery <- gallery ++ [await Generate(images, model, p)]
  }
}

tool Generate(drive: Drive, model: Model, prompt: Text) ~> ImageId {
  return await model.image(prompt, into = drive)         葉が drive に直接書き、id を返す
}
```

- id は Data なので state に入る。有効性は drive の寿命に従う。drive は Studio より上で宣言されるので、Studio の生存中は有効
- drive が差し替わると（別 bucket）、gallery の id は参照先を失う。`drive.get(id)` は Fault。「id は drive の同一性と組で意味を持つ」を指針に書く `[P 9]`
- 画像の bytes を tool の結果（Data）で運ぶ形（`let bytes = await model.image(p); await drive.put(bytes)`）も書けるが、大きな Data が Katari を通る。
  葉に drive を渡す形（上）を stdlib の既定にする

## 10. phase を書き忘れる場面

| 場面 | 既定（sync 区間 = phase）で何が起きるか | 対処 |
|---|---|---|
| 同じ pool を await を跨いで 2 回読む（§2 の 1 つ目） | 2 回目は新しい要素。返信先が変わる | lint: 「await を跨いで同じ pool を読んでいる。phase で囲むか let に写す」 |
| 要素を `let` に束縛して await を跨ぐ（§2 の 2 つ目） | 解放済みの要素を使って Fault | `[P 3]` で構造的に塞ぐ（let の scope が phase） |
| `use r = kind(ch) { … }` のブロック | ブロックが phase。問題なし | — |
| loop の先頭と末尾で props を読む | 別の値になりうる | 同上の lint |
| tool の引数に pool の要素を渡す | call 時に固定。問題なし | — |

既定で正しさ（dangling なし）は保てる（`[P 3]` 込み）。残るのは「1 反復の中で旧と新が混ざる」という意味の問題で、lint で十分。

## 提案

1. **should** spec に「phase は run の読みだけを固定する。宣言は固定しない（構造は追従し、過程は今の step を旧入力で終える）」「phase は state の commit を遅らせない」を明記
2. **must** plan / trace に pending な update（uid、待っている run の位置と経過時間）を出す。3 段上の親が何を待っているか分からないと運用できない
3. **must** run の `let` に束縛した pool の要素は、その scope の間 phase を延長する（`use r = … { }` のブロックと同じ扱い）。無いと解放済みの要素を使って Fault する
4. **should** `for c in ch key … { … }` の綴りを捨て、要素を同一性にしたい場合は `use conv = Conversation(ch, …) key ch.id` と書く
5. **should** `destroy_first` の kind は update せず replace（dispose → init）する。空への update を protocol に足さない。`destroy_first` と `updatable` の否定は同じもの
6. **should** `updated(uid)` はそれ以前の uid を含意する。親は最新の ack より古い要素を全て解放してよい。途中の要素を飛ばしてよい
7. **nice** Faulted な run は updated を妨げない、と明記
8. **nice** Data だけの update は ack を待たない（runtime の省略）
9. **nice** drive の id は drive の同一性と組で有効、を指針に。葉に drive を渡す形を stdlib の既定にする

## 書き手が驚く点の上位 5 つ

1. 同じ component の中で宣言は新しい要素、run は旧要素、という混在が phase の間続く
2. 数日の `await human.ask` を phase で囲むと、3 段上の親まで旧 resource を解放できない（見えないと不安になる）
3. phase 無しだと、受け取った message への返信が新しい channel に出る
4. `let c = ch` が解放済みの要素になりうる（`[P 3]` で消える）
5. `destroy_first` の kind では、差し替えの窓で message が失われる

## 未決の問い

- `updated` を返せない子（phase の中で無期限に待つ）に対し、親が「待たずに解放する」選択肢（強制の dispose 以外）を持つべきか
- update の連打で kind が持つ接続数の上限（create-first は連打の回数だけ接続を持つ）
- Data だけの update で ack を省略すると、親の「配下が乗り換えた」という知識が弱くなる。plan の正確さに影響するか
