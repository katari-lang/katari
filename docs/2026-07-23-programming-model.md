# Katari のプログラミングモデル — 暗黙にしない 5 か条(v0.1.x)

runtime が型やエラーで強制**できない**、しかし正しいプログラムを書くのに必須の規則がちょうど 5 つある。
どれも違反すると **silent に misbehave する**(コンパイルエラーにも panic にもならない)。docs の各設計文書に
散っていたものをここに集める — v0.1.x のユーザーが最初に読むべき 1 ページ。

## 1. 外部呼び出しは at-most-once

FFI / http / mcp transport の呼び出し中に runtime が再起動すると、その呼び出しは**再実行されず**
catchable panic(「interrupted by a runtime restart」)になる。二重実行より失敗を選ぶのが既定。

## 2. retry は組み込まれていない — `replay` を自分で組む

再試行が欲しい場所には `prelude.replay` の provider(`immediate` / `exponential` / `forever`)と、
「どの throw を `replay.interrupted` に変換するか」の converter を自分で書く。converter を忘れた
watch / run は、一時障害 1 回で死ぬ。頻出形には `replay.on_throw` 系の糖衣を検討中。

## 3. retry したら冪等化も自分の責任

replay を組んだ瞬間、end-to-end は at-least-once になる。Discord へのメッセージ送信のような外向きの
副作用は**重複しうる**。dedupe の材料は自分で持つ: `time.watch` の tick なら scheduled epoch ms、
その他は `store` に記録した処理済みキー。runtime に idempotency-key 機構はない。

## 4. daemon は再帰ではなく `forever`

再帰は 1 回ごとに durable frame を積む(tail-call collapse はない)。無限再帰は durable state を無限に
成長させ、いつか止まる — コンパイルエラーにも depth limit にもならない。常駐ループは `forever {}`
(frame が平坦)で書く。有限の再帰(接続リストを畳む等)は問題ない。

## 5. served endpoint の body は handler で包む

`mcp.serve` / `webhook.inbound` が公開する agent が unhandled throw / panic を起こすと、**その 1 呼び出し
ではなく endpoint 全体が落ちる**(failure は一様に proxy される — 意図された設計)。per-request の耐性が
欲しければ、公開する agent の body を自分で handler で包む(`prelude.catch` / `catch_all` が最短)。

---

補足(5 か条ではないが近くに置く価値のあるもの):

- **`katari apply` は走行中の run に効かない。** run は起動時の snapshot に pin される。`forever` で回る
  bot を新コードに乗せるには手動で cancel → 再 run(`store` の KV は残る。`var` や watch cursor は消える)。
- **`http.fetch` の非 2xx は正常な結果値**(`status` で分岐する)。エラーになるのは応答が返らなかった
  ときの `fetch_error` だけ。
- **`time.watch` の tick は at-least-once**(crash 窓で同一 occurrence が再配信されうる)— §3 の dedupe は
  scheduled time で。

- **fiber は結果を持たない(join は存在しない)。** fork の task は `-> null`: fiber の成果は必ず escalation で
  運ぶ(最後の 1 行で報告する)。settle した値は discard され、durable な残骸はゼロ。「parallel は待つ、
  region は聞く」— 値を待ち合わせたいなら `parallel`、detach したいなら region。panic だけは system が watch
  経由で知らせる(自力で報告できない終わり方だから)。
- **region の並列度は watch の本数で決まる。** fiber の escalation は watch 1 本あたり 1 件ずつ
  (答えが返るまで次を出さない)再放出される。並列にするには `region.watch_many(nursery, width)` **と**
  受け側の `parallel handler` の両方が要る(直列 handler は自分の FIFO で再直列化する — それが正しい場面も
  ある: chat loop はメッセージ順 = turn 順が仕様なので watch 1 本を保て)。実測: width=2 + parallel handler
  で 2 件の escalation 処理が重なり、width=1 では 2 件目が 1 件目の答えを待つ。
- **fiber の escalation は watch 設置まで durable にバッファされる。** watch がまだ無い nursery の fiber
  escalation は run root へ漏れたりせず(provide の宣言 row は `R with Eouter | io` で fiber の `E` を含まない)、
  nursery の durable mailbox に到着順で溜まり、watch が設置された瞬間に再放出される。だから fiber は fork 直後に
  escalate してよい(先頭を sleep で遅らせる必要はない)し、watch は任意に遅れて設置してよい — 起動レースは無い
  (2026-07-25 M2-6 で quiescence flush-up を全廃)。
- **region から値で抜ける公式の形は「handler の `break`」。** watch を覆う handler の clause が `break v` する
  と、v が provide の結果として返る(構造化並行の「答えを出して畳む」終わり方)。use で抜けるブロックの型は
  その application の結果型(break union 込み)として推論される — かつては never に潰れて runtime の schema
  panic になっていた(2026-07-23 修正済み)。
