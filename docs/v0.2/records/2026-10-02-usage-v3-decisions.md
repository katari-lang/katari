---
title: v3 評価の提案と採否
description: usage-v3/ の 5 本の評価が v3 基底に出した提案ごとの採否と理由。2026-10-02-spec.md への反映箇所
---

評価: `usage-v3/chat-and-channels.md`、`workflows-and-patch.md`、`ai-and-attach.md`、`runtime-and-protocol.md`、`ux-and-abstraction.md`。
対象: `2026-10-02-spec-base-v3.md`。反映先: `2026-10-02-spec.md`（第 3 版）。

## 複数の評価が一致した提案

| 提案 | 出所 | 採否 | 反映 |
|---|---|---|---|
| run の中の await / resource の address 規則（`let` 名、`tool名·出現番号`、反復 key） | chat 1, wf 2, rt 5 | 採用 | §1.2, §2.1 |
| run の終了と失敗の可視化（暗黙の `status`、uncaught Fault は Faulted） | chat 8, wf 3, ai 1 | 採用 | §2.3 |
| `select`（channel 向け。負けた receive は item を失わない） | chat 4, wf 6, ai 12 | 採用。`merge` は stdlib | §2.1 |
| run から body の宣言を読む（`await x`。when 下は Option、for 下は Map） | wf 4, ai 3 | 採用 | §2.1, B5, B6 |
| 変化を待つ `for await x in sig` / `changed` | wf 7, ux 2, ai 未決 | 採用（`for await`）。導出データは stdlib `derived` | §2.4 |
| channel の未定義（容量、順序、close、dispose 時、単一消費者、背圧） | chat 9, ux 3, ai 2, ai 5, rt 6 | 採用 | §4 |
| `par(list)` の要素 key と動的個数 | wf 8, ai 8 | 採用 | §2.1 |
| `for` の出力を map で受ける（pool / member の廃止） | chat 6, ux 4, ai 11 | 採用。`channels<K,T>` は stdlib | §1.4 |
| props は全て update 可能で run は続く | ux 1 | 採用 | §1.1 |

## チャット・channel

| # | 提案 | 採否 |
|---|---|---|
| 2 | 自分の書き込みは同じ区間で即座に見える | 採用（§2.2） |
| 3 | run は参照する use の出力が揃ってから開始 | 採用（§2.2） |
| 5 | `channels<K,T>` に `drop(k)` | 採用（§4） |
| 7 | dedup は message id（kind の指針） | 採用（§4） |
| 10 | run 内 resource の args は読んだ時点の値。長く使うものは body の use | 採用（§2.1） |

## ワークフロー・patch

| # | 提案 | 採否 |
|---|---|---|
| 1 | race は負けの ↑ を待つ。interruptible: false なら止まる | 採用（§2.1） |
| 5 | kind に `on_dispose: delete \| detach` | 採用（§5） |
| 9 | 送り手が消えたら未受信を取り下げる `mailbox` 変種 | 不採用。channel の意味（送ったものは事実）を保ち、相関 id の指針で扱う（§9） |
| 10 | state の reset と run の位置を 1 単位で扱う | 採用（§7） |
| 11 | migration の `at` に反復 key の wildcard | 採用（§7） |
| 12 | run に `finally` | 採用。「unmount hook 無し」を run の finally に限って緩める。↑ は finally を待つ（§2.3, B3） |

## AI・attach

| # | 提案 | 採否 |
|---|---|---|
| 4 | run は宣言につき 1 回。再実行は key | 採用（§2.3） |
| 6 | 外部が Katari の tool 値を呼ぶ規則 | 採用（§3） |
| 7 | lambda は純粋な式の中だけ | 採用（§2.1） |
| 9 | Tools に fn を直接入れる | 採用（§3） |
| 10 | 1 回の結果は export state、繰り返しは channel | 採用（§9） |

## runtime・protocol

| # | 提案 | 採否 |
|---|---|---|
| 1 | event 源は kind の `events: T` 宣言。runtime が channel を materialize。ack は永続化後 | 採用（§4, §5） |
| 2 | 自分の state だけを待つ `await sig` は静的エラー | 採用（§2.2） |
| 3 | frame に保持する子ノードの address 集合 | 採用（§6） |
| 4 | channel の item 型変更は migration か drop。無ければ BLOCKED | 採用（§7） |
| 7 | mailbox は親が作って配る（子の export の相互渡しは循環） | 採用（§4） |

## UX・抽象

| # | 提案 | 採否 |
|---|---|---|
| 5 | `with` を run 内の `use … { … }` に統一。本文は `run` だけ | 採用（§2.1） |
| 6 | run の未処理 Fault と loop を抜けた後の扱い | 採用（§2.3） |
| 7 | `await sig` を型で限定 | 採用（§2.1） |
| 8 | state の多地点更新の糖衣 | 不採用。channel + loop の command パターンを指針に |
| 9 | CPS 用語を付録へ | 採用（付録 A） |
| — | 「宣言が消える = destroy」を最初に言う、「durable な Channel」と言う | 採用（§0） |

## 未決に残したもの

- event 源が replace されたときの buffer: 捨てる（args が変わった源の message は別物）と決めた（§4）
- 1 つの ReceiveChannel の複数消費: 単一消費者。lint（§4）
- `await sig` が Pool の集約のとき: Pool が無くなったので消滅
- 区間の実行時間の上限、`finally` の長い待ち、supervisor、`select` の細部、`kind` カテゴリ、`using caps`、tool 値の型表現: §10

## 2 段階 update と phase の評価（2026-10-02、`usage-v3/update-and-phase.md`、`provider-and-update.md`）

| 提案 | 採否 | 反映 |
|---|---|---|
| phase は run の読みだけを固定し、宣言は固定しない。commit も遅らせない | 採用 | §1.6 |
| plan / trace に pending な update（gen、待っている run の位置、経過時間） | 採用 | §1.6, §7 |
| `let` に束縛した要素は scope の間 phase を延長する | 採用 | §2.1 |
| `for c in ch key …` の綴りを捨て、`use … key ch.id` で要素を同一性にする | 採用 | §1.5 |
| destroy-first は update せず replace（継続も召喚し直し。state が消えることを plan に） | 採用。`destroy_first` を廃止し「updatable でない引数の変化 = replace」に統一 | §1.6, §5 |
| `updated(g)` は以前の gen を含意。中間の要素は飛ばしてよい。uid = gen | 採用 | §1.6 |
| Faulted な run は updated を妨げない | 採用 | §1.6 |
| Data だけの update の ack 省略 | runtime の最適化として可。仕様には書かない | — |
| drive の id は drive の同一性と組。葉に drive を渡す形を既定に | 採用 | §9 |
| handle を含む args の host への届き方（参照先の出力の Data 部分 + 不透明 id） | 採用 | §5 |
| 出力が変わらない update は継続に流さず即 updated | 採用 | §1.6 |
| `failed(id, gen?, error)`。失敗は旧要素のまま Faulted(UpdateFailed)、drift を plan に。自動 retry しない | 採用 | §1.6, §2.3, §5 |
| 連打: 最新の gen に跳ぶ。host は継続に流す前の作成を中止してよい | 採用 | §1.6 |
| `updatable` を kind から外し呼び出し側の key で表す | 不採用。kind の能力は provider が知っているので宣言のまま。key は「要素を同一性にする」ための呼び出し側の選択 | — |
| 外部 event 源も `to: SendChannel<T>` を取り、materialize と `events` 宣言を消す | 採用。例の `select` も直和の inbox 1 本に置き換えた | §4, B1, B2, B6 |

残した未決: updated を返せない子に対する「待たずに解放する」手段、create-first の接続数の上限、drift の再試行の起点、
`interruptible: false` の葉を束縛した phase の cancel 時の待ち順。

## phase の廃止（2026-10-02）

- `phase { … }` と「tool の引数は call 時に固定」を廃止。pool は区間ごとに最新を読む（Katari の tool body も同じ）
- **handle 型の let は await を跨げない**（型エラー）。資源安全を静的に保証し、let が解放を止めることも Fault も無い
- 走行中の葉の呼び出しとブロック resource は、handle の要素が変われば cancel → 新しい要素で呼び直す（既定）。
  `interruptible: false` の kind だけ完了を待つ。解放の遅延はこれだけで、plan に出る
- 理由: handle の差し替えは設定の変更（移転、廃止）で、古い場所に出した呼び出し（human.ask）は新しい場所に出し直すのが望まれることが多い

## 参照と値の区別の廃止（2026-10-02）

- 言語から Data / handle の kind を消した。名前は全て pool、`let` は pool を束縛し、要素を握る手段は無い（資源安全は構造）
- 葉は引数ごとに `on_change: restart | update | finish` を宣言する（`updatable` と `interruptible` を統合）。反応の責任は葉にある
- 永続化は値か pool の address。AI に見せる tool の引数が値であることは `describe` の問題

## 第 4 版への統合（2026-10-02）

- component は 1 つの inbox（`receives Msg`）と 1 つの出し口（`event E`）。`=> Tag` は子の event を inbox に流す配線。
  `channel<T>()` / `export send` / `to:` / `select` / `close` を廃止
- 出力は export の直積。export 無しは `Unit`（Void は無い。無限待ちが起きない）
- send は依存先（継続である相手）へだけ。`x.send` は run が x に依存しているから書ける（子→親の向き）。inbox の send 側を値として配らない
- `receives` 無しの component に send は型エラー。受け取って無視する形は無い
- run の開始は参照する無条件の宣言が揃ってから、終了は参照する宣言より先（finally で使える）
- 「kind」を「外部 component」に改称

## 親 → 子の send の廃止（2026-10-02）

- 前向き（親 → 子）は props だけ。`x.send` を廃止。`receives` は何も export しない
- inbox は run と一緒に作られる内部ノード。`=>` で配線した宣言は inbox に依存し、run はそれらを参照できない（循環。静的エラー）
- 子が外部の event を受けたければ子が自分で源を購読する（フィルタは props）。agent の 1 ターンは tool（引数 = 今の history）
- 理由: 双方向の event のやり取りを言語から無くし、「state は前へ、event は後ろへ」を徹底する

## 訂正: send は残す（2026-10-02）

- 前項の「親 → 子の send の廃止」を撤回。`x.send` は依存先へなら可
- inbox は run の後ろのノード。`=>` で配線した宣言は inbox に依存し、run はそれらを参照できない（相互参照は静的エラー）
- 1 つの子と話す向きは 1 つ。send する子からは event を受けず、event を受ける子には send しない。反対向きは state（export state / props）。
  `x.events` のような分離の機構は持たない

## tool = event を 1 回出す component（2026-10-02）

- `tool T ~> R` ≡ `component T { event Done(Outcome<R>); run { emit Done(…) } }`、`await T(a)` ≡ frame の下に `=> Done` で宣言して待つ
- frame の子（await）の event は frame に直接届く。body の子（`=>`）の event は inbox に届く。区別はこれだけ
- tool の性質（引数は pool、親の state を書けない、cancel = dispose）は全て component の性質から出る

## receives の公開範囲（2026-10-02）

- `receives Msg` は既定で内部用（`=>` の子の event だけが入る）。`export receives Msg` のときだけ `x.send` が出力に含まれ、親が送れる

## 表層構文の決定（2026-10-03、`2026-10-03-syntax.md`）

- 4 案（HCL 風 / Kotlin 風 / 最小 / 保守的改良）を比較。採ったもの: header の矢印 `<- Msg -> E`、配線 `-> Tag`、send `x <- m`、state `s <- v`、
  `receive` / `receive all` / `receive Pat if c`、`wait`、`with`、`step`、`name:` ラベル、`tool T(args): R`、`external … { … }`、migration ブロック
- 退けたもの: 文字列ラベル、`val` / `var`、`async fn`、`emits Tag`、`parent <- e`、`await { expr }`、`export receives`
- spec 本文と付録の例を同期した

## 慣習と細部（2026-10-03）

- state は通知に使わない。親が逐次で待つなら tool、宣言で寿命を決めて反応するなら子 component + event、観測は export state、命令だけ `<- Msg`
- agent は middleware（channel を自分で購読し、結果を event で上げる）。`wait … changed from` は廃止
- `let` は式を今評価する（data はコピー、resource は参照）。`var` を run / tool の局所可変として戻す（tool に state が無いため）。state の初期値は init 時に 1 回
- selective receive の複数節 `match receive A(x) | B(y) { … }` を追加。loop は 1 つのまま
- `let` は名前（pool なら読むたびに今の要素）、`var` は箱（data だけ、宣言時の値が初期値）。resource を凍結する手段は無い。`wait … changed` は不要と確定

## tool の中に時変値は無い（2026-10-03）

- tool の引数は call 時の要素で、data も resource も不変。要素の差し替えは tool call の外側で `restart`（既定）/ `finish`（定義で宣言）として扱う。外部の葉と同じ規則
- 参照 / 値を意識する場所は無い。時変値が見えるのは run の中だけ
- ワンショットの仕事は tool（`Orchestrate(goal)`）、常駐は component（goal は event）。Katari component の params に `restart` を宣言する案は不要

## restart / finish の廃止（2026-10-03）

- tool call は宣言一般の規則（引数が変われば作り直し）に従う。引数ごとの反応の宣言は無い
- `atomic`（始まったら作り直しも中断もされない。走行中の引数変化は旧引数で完走し drift として報告。dispose は完了を待つ。patch の作り直しは plan がブロック）が
  `replace: forbidden` / `interruptible: false` / `finish` を 1 つに統合。resource の引数ごとの `update` だけが残る

## 環境の列（2026-10-03）

- 可変値を語彙から消した。環境（ある時点の全名前の値、不変）の列があり、越えるのは instance（identity。今の要素に解決）・state（前から次を作る）・phase の出力（let の data）だけ
- tool call は 1 つの環境で完走する phase。親の再設定は次の call から。走行中は握っている要素を解放しない（CI の runner と同じ。plan に出る）。dispose だけが即時
- resource は宣言名で参照し、let に束縛しない。tool の中では resource の export を読めない（tool を呼ぶだけ）
- `atomic` は「dispose されても完走する」だけの葉の宣言に縮小
- phase を run の構文として復活: `phase x = { …; return y }`。中は 1 つの環境（resource の束縛も可）、越えるのは出力の data だけ、state の書き込みは phase の終わりに反映。
  書かなければ sync 区間が暗黙の phase。tool = 名前付きの phase。resource を握るのは phase の間だけ（意図した挙動）
