---
title: usage 評価の提案と採否
description: usage/ の 4 ドメイン評価が出した提案ごとの採否と理由。2026-10-01-spec.md への反映箇所
---

4 つの評価（`usage/chat-bots.md`、`usage/workflows.md`、`usage/ai-agents.md`、`usage/runtime-and-patch.md`）が
`2026-09-30-spec-base.md` に対して出した提案の採否。採用したものは `2026-10-01-spec.md` に反映済み。

## 複数ドメインが一致した提案

| 提案 | 出所 | 採否 | 反映 |
|---|---|---|---|
| tool の失敗を 1 本の Sink で `Result` として運ぶ。`Interrupted` を含める | chat P1, wf P2, ai P3, rt P1 | 採用。`Outcome<R> = Ok \| Fault`、`Fault = Failed \| Interrupted`。想定内の失敗は `Result` を値で返す | §2.3, §4.4 |
| ループ反復ごとに address を拡張する | ai P1, rt P2 | 採用 | §3.4 |
| kind の静的宣言（updatable、replace: forbidden、interruptible、on_restart） | wf P7, rt P7 | 採用。fake にも要求 | §4.3 |

## チャットボット

| # | 提案 | 採否 | 理由 / 反映 |
|---|---|---|---|
| P1 | 失敗の経路を構文に | 採用 | 上記 |
| P2 | bare の子の label = 最後の名前。重複は key 必須 | 別解で解決: bare 宣言を廃止し、全て `use x = …` で束縛名を label にする | §1.4 |
| P3 | `when` / `for` の中の sync tool は囲む component の State を書ける | 採用 | §2.1 |
| P4 | filter 付き watch を kind 設計の指針に | 採用 | §2.5 |
| P5 | sync → sync の呼び出しは同期。1 遷移で commit | 採用 | §2.2 |
| P6 | bare と use の統一 | 採用。全て `use`。Void の束縛は参照すると型エラー | §1.1 |
| P7 | 時刻の供給源 `time.clock` | 採用 | §2.9 |
| P8 | render は遷移ごと | 採用 | §1.6 |

## ワークフロー

| # | 提案 | 採否 | 理由 / 反映 |
|---|---|---|---|
| P1 | `=> h` 宣言に label（`ask: T(a) => h`）。instant の値を sync tool に流す | 採用。その後 `use x = T(a) => h` に統一（全宣言が束縛名を持つ） | §2 |
| P2 | 失敗は 1 本の Sink | 採用 | §2.3 |
| P3 | `send(from, …)`。dispose 発行済みノードからの送信を捨てる。両方向 at-least-once | 採用 | §2.5, §4.1 |
| P4 | tool body に `race` | 採用 | §3.2 |
| P5 | `after x` は埋まり直しに依存 | 採用 | §2.4 |
| P6 | 「捕捉先が消えた走行中 tool は cancel」を削除 | 採用 | §6.1 |
| P7 | interruptible / idempotency の宣言 | 採用（idempotency は「id を冪等キーにする」を葉の規則として §4.2 に） | §4.2, §4.3 |
| P8 | for の iteration export を Pool として受ける糖衣 | 保留 | §9 |

## AI エージェント

| # | 提案 | 採否 | 理由 / 反映 |
|---|---|---|---|
| 1 | ループ反復の address | 採用 | §3.4 |
| 2 | `await for` | 採用 | §3.2 |
| 3 | 失敗の形 | 採用 | §2.3 |
| 4 | tool の部分適用 | 採用 | §2.2 |
| 5 | Pool の自己登録 | 採用: 層化を規則にし、top-level の `member self` + `for` の読みは通ることを明記。巡回は静的エラー、成長は遷移を挟む | §2.6 |
| 6 | 走行中の tool call の args snapshot | 採用: `key` があれば args の変化で作り直さない | §2.4 |
| 7 | `check` を validate と link に分ける | 採用 | §7 |
| 8 | `Interface` を Data にしない。`describe(I)` | 採用 | §7 |

## runtime / patch

| # | 提案 | 採否 | 理由 / 反映 |
|---|---|---|---|
| 1 | `Result<R, Fault>` と on_restart | 採用 | §2.3, §4.4 |
| 2 | ループ反復の address | 採用 | §3.4 |
| 3 | 継続の入力を SoT に保存 | 採用 | §5 |
| 4 | moved と host の id の分離 | 採用: id は runtime が振る不透明値。address ↔ id の対応表 | §4.2 |
| 5 | instant の再実行規則の明示 | 採用: key の有無で決まる（instant は `use` に統一） | §2.4 |
| 6 | plan に「以前 init された id への init」を注記 | 採用 | §4.2, §6.3 |
| 7 | kind の静的宣言を interface に | 採用 | §4.3 |

## 違和感として記録されたもの

- 1 回の tool call が init / send / dispose / disposed の 4 メッセージ: protocol 上は正しい。runtime 実装で tool 葉向けに省略可能（意味論に影響しない）
- `use` の replace が継続全体を cascade する: terraform の ForceNew と同じ。plan が範囲を示す
- migration の左辺が body の state 全体の record: reset の単位と揃えるため維持
- `use pr = gh.pr(branch) after impl` で impl が作り直される間、継続が引っ込む: 正しい挙動。`after` は必要な所だけに使う（§6.4 の指針に含めない。usage の記録で足りる）
- 全域性の要求で遷移が `match (state, event)` になりがち: P3（古い送信を捨てる）で減る
- 伸び続ける State を store に逃がす経路: 未決に記録
- 決済の retry を `key attempt` で書くと冪等キーが変わる: 指針に記載（§6.4）
- 子が親の inbox を消費する Sink の定型: 既定は callback（親の State に溜める）。受信箱 Pool は外部キューの消費に使う（§2.5）
- stdlib の tool の locals が patch の互換判定に乗る: 未決に記録

## 未決の問いの扱い

| 問い | 扱い |
|---|---|
| model が同じ call id を 2 回出す | runtime が連番を足す（§8） |
| mcp.serve で外部が親になるときの address | `srv·(call, id)` を Katari が振る（§8） |
| streaming の遷移頻度 | runtime 設計。未決 |
| 受信箱 Pool の dead-letter | kind に任せる。未決 |
| `time.cron` の取りこぼし | 葉の責任（§4.4 の再起動契約の一部） |
| 外部が落ちている間の dispose | 連番付き at-least-once で復帰後に届く（§4.1） |
| interruptible: false の親が待つ間の同 address 再宣言 | disposed を待ってから init（§4.1, §4.3） |
| 履歴・監査ログの置き場 | 未決 |
| `race` を component 形の糖衣にできるか | できる。tool body の糖衣として持つ（§3.2） |

## 評価後の統一（2026-10-01）

component と middleware の区別を無くし、宣言を `use x = M(args) [key k] [=> h]` に統一した。bare 宣言、`instant`、
`name: T(a) => h` の label 記法は消えた。根拠: body は宣言の集合で依存は自由変数なので、`use` の nest は「x を参照する宣言だけ」に
かかる。継続に渡すのは self で、self は export にしか依存しないので、Void の子は何も遅らせない。

## 第 2 版での変更（2026-10-01、統一の続き）

議論の結論を第 2 版の spec に反映した。

- 出力を signal（export）と event（`event E` / `emit`）の 2 軸に分けた。transition を起こすのは event だけ。
  signal の変化を event に還元する案（`=> Tag(e)` の値変化で発火）は退けた
- Sink / port は無い。event は `use` した親の `=> Tag` にだけ届く。転送は明示
- tool は kind の性質で区別される普通の component。tool body は component body の逐次記法で、
  追従は dataflow（変わった入力の下流だけ）。状態機械展開（pc + locals）は、引数変化時に call 全体をやり直すか
  古い locals と新しい引数が混ざるかのどちらかになるため退けた
- body 内 tool 定義、tool の等級、`State<T>` / `&s` / `bind`、`key` による凍結は無い。固定は transition で State に写す
- protocol は 1 組（init / update / dispose / disposed + 子→親の event）
