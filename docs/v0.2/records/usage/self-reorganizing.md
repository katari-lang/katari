---
title: usage 評価 — AI が組織を組み替える、capability の制御
description: AI が Katari を生成し、plan を読み、migration を書いて apply する閉ループ。node の下で何が許可されているかを handle と env で制御する形。v0.1 の effect / coeffect との対応
---

対象は `../2026-10-01-spec.md`。この評価で決まったことは spec の §7.1、§10 に反映した。

## 1. AI が能動的に組み替える組織

`usage/ai-agents.md` §8 は「生成して attach する」までで、生成し直したときの migration は人間が書く前提だった。
AI が自分で組み替えるには、次の 3 つが Data として AI に見える必要がある。

```
reflect(d)                      : 現在の構造。address 木、各ノードの State の型と値の要約、依存 DAG、走行中 tool の label
plan(d, src', migration?)       : 差し替えたときの Diff（keep / update / replace / migrate / reset / BLOCKED と、reset 後の render）
validate_migration(d, src', m)  : migration の型検査。Result<Unit, Errors>
```

`d : Definition<I>` は `link` の出力で、現在 mount されている定義の handle。3 つとも tool（Data の結果）で、副作用は無い。
apply は `link` の args（src と migration）を変えること。

```
component Plastic(spec: Text, env: Env, model: Model, ops: Human, args: I) {
  state cur:      Option<(Text, Text)> = None          (src, migration)。migration は初回は空
  state proposal: Option<(Text, Text, Diff)> = None

  tool proposed(o: Outcome<(Text, Text, Diff)>) = match o { Ok(p) => proposal <- Some(p), Fault(_) => skip }
  tool decided(o: Outcome<Decision>) = match (o, proposal) {
    (Ok(Approve), Some((s, m, _))) => cur <- Some((s, m)), proposal <- None
    _                              => proposal <- None
  }

  when cur is None { Generate(model, spec, describe(I), env) => proposed }

  when cur is Some((src, m)) {
    use d = link(src, env, I, migration = m)
    d(args)

    when proposal is None {
      Reorganize(model, spec, d, env) => proposed             次の案を作る（trigger は spec や観測の変化）
    }
    when proposal is Some((_, _, diff)) {
      ops.ask_once("apply?", diff) => decided                 人間が Diff を見て承認
    }
  }
}

tool Reorganize(model: Model, spec: Text, d: Definition<I>, env: Env) ~> (Text, Text, Diff) {
  let now = await reflect(d)
  var errors = []
  loop {
    let (src, m) = await ai.infer_json(model, prompt(spec, now, errors), schema = (Text, Text))
    match await validate(src, env, I) {
      Err(es) => { errors = es; continue }
      Ok(()) => match await validate_migration(d, src, m) {
        Err(es) => { errors = es; continue }
        Ok(()) => {
          let diff = await plan(d, src, m)
          if diff.blocked != [] { errors = blocked_as_errors(diff); continue }     replace: forbidden に当たった
          return (src, m, diff)
        }
      }
    }
  }
}
```

### runtime の挙動

```
遷移     decided(Ok(Approve))。cur = (src', m)
render   Plastic·d の args が変わる。link は updatable: [src, migration] なので update(d, {src', m})
         d の配下（Plastic·d·…）が新しい定義で reconcile される。m が non-compatible な state を移し、
         残りは address で keep。plan で見た Diff と同じ差分が発行される
```

- 生成された定義の State は address で引き継がれる。AI が label を変えると reset になるので、plan の Diff がそれを示し、
  AI は `moved` を migration に書くか label を戻す。人間のデプロイと同じ規律を AI に課している
- 承認は `ops.ask_once` の 1 ノード。承認なしで組み替えさせたいなら `decided` を `proposed` に直結する（構造は同じ）
- `Reorganize` が走っている間に `spec` が変わると args の変化で作り直される。長い推論を守りたければ `key` を付ける
- root を Plastic にすれば組織全体が AI 管理になる。`katari deploy` は `cur` への書き込みと同じ経路

### 評価

- 閉ループは仕様の道具（tool、use、`=> h`、link、when）だけで閉じる。新しい意味論は要らない
- 必要だったのは `reflect` / `plan` / `validate_migration` を **tool として** 持ち、`link` が migration を args に取ることの 2 点。spec に追加
- plan が Data なので、AI だけでなく人間の UI も同じものを描く（presentation as data）

## 2. capability の制御

「この node の下では discord への接続が許可されている / されていない」は、handle の有無で表す。

```
component Org(caps: { discord: Discord, model: Model, http: Http, time: Time }) {
  Sales(caps)                                            全部渡す
  Research({ model = caps.model, http = caps.http })     discord を渡さない
  Intern({ model = caps.model })                         model だけ
}
```

規則:

```
ambient authority は無い     全ての kind は provider handle を要求する（http.get(http, url)、time.clock(time, …)）
                             root は runtime の設定から provider を受け取る
handle は下にしか流れない     params、use の出力、for の束縛（§1.5）。上に戻るのは出した者へだけ（export）
record は幅の部分型           { discord, model, http } は { model } の所で使える。子は宣言した型の field しか参照できない
動的な定義は I で検査される    link された定義が触れる handle は args の型 I に列挙されたものだけ。名前は env
```

「許可されていない」は「渡していない」で表し、それ以外の表現を持たない。

### 見えること

- **静的**: component の params の型が、その subtree が使いうる capability の上界。`Intern({ model })` の下に discord は現れない。
  型検査が保証する（v0.1 の coeffect row に相当するが、推論ではなく宣言）
- **動的**: 依存 DAG と address 木を見れば、どの provider から何が生えているかが分かる。plan は差し替えでどの capability が増減するかを
  そのまま示す（v0.1 で escalation report が capability diff だったのと同じ役割）

### 減衰と失効

```
use budgeted = model.with_budget(caps.model, tokens = 200_000)      減衰。子は元の model に触れない
use scoped   = discord.only(caps.discord, channels = ["#sales"])    減衰。kind が提供する
when allowed { Sales(caps) }                                        失効 = 宣言が消える。cascade で dispose
```

減衰は「元の handle を包む resource」で、kind が提供する。失効は宣言の消滅。

### 漏れないことの確認

| 経路 | 到達できる者 | 漏れか |
|---|---|---|
| params | 親が渡した子 | 親の意図 |
| `export` | その component を `use` した親 | 親は元の handle を持っている |
| Pool の要素（Type） | pool の読み手 | pool の所有者が `Pool<B>` の B に handle 型を含めて宣言し、読み手に pool を渡している。所有者の意図 |
| Sink | 渡された者 | 送信先の所有者の意図 |
| 動的な定義 | I と env で検査 | 検査済み |

上向きに handle が動くのは `export` と `member` だけで、どちらも受け手（親、pool 所有者）が型でそれを宣言している。

## 3. v0.1 の effect / coeffect との対応

| v0.1 | v0.2 での対応 |
|---|---|
| effect row（perform しうる request の集合） | params の handle 型の集合。宣言で、推論しない |
| handler / provider（request の実装） | provider handle と kind。`use` で得て下に渡す |
| handler の差し替え（テスト、per-AI） | 別の handle を渡す（fake、with_budget、scoped） |
| effect polymorphism（row 変数） | record の幅の部分型。子は必要な field だけを型に書く |
| coeffect（credential、資源の要求） | params の handle 型 |
| 未処理の request → 人間への escalation | `human.ask` の handle を持つ component が自分で宣言する。「未処理」という概念は無い |
| escalation report（capability diff） | plan と依存 DAG |
| scope（handler の有効範囲） | 宣言の寿命。cascade |

真に失われるのは **推論** だけ。v0.1 は body から row を推論したが、v0.2 は handle を明示的に受け渡す。
深い木では prop drilling になる。緩和は `caps` の record を 1 つの param で渡すことと、record の幅の部分型。
implicit parameter（`using caps`）は糖衣の候補として未決に置く。

effect / coeffect の機構を別に持つ理由は無い。handle の受け渡しが同じ保証を、宣言だけで与えている。
