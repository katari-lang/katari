---
title: Katari v0.2 表層構文の要件
description: 意味論は固定し、表層構文だけを設計し直すための機能要件。構文案は syntax-proposals/ に置く
---

意味論は `2026-10-02-spec.md`（第 4 版）で固定されている。ここでは **表層構文が表現しなければならない機能** だけを列挙する。
既存の構文は参考にしなくてよい（むしろ引きずらないこと）。

## 言語の性格

- 動的な terraform。宣言した構造を runtime が差分で init / update / dispose する。React のコンポーネントと reconcile、terraform の address と plan を借りている
- 各 component は 1 つの inbox と 1 本の逐次 loop（Kotlin の coroutine、actor）を持つ。loop だけが自分の state を書く
- 通信の向きは 2 つだけ。前向き（親 → 子）は state（props）と「子の inbox への send」、後ろ向き（子 → 親）は event。
  1 つの子に対して向きは 1 つ: send する子からは event を受けない、event を受ける子には send しない
- 読者は React、async/await、terraform を知っている。Katari は知らない。3 文で説明できる構文であること

## 表現しなければならない機能

### A. component 定義

1. 名前と params（型付き）。params は親から渡され、時変（親が変えれば更新される）
2. body は **宣言の集合**（順序なし）。宣言の種類は下の B〜E
3. 出力 = export された宣言の直積（record）。export が無ければ Unit
4. inbox の message 型（直和）。既定は内部用（自分が配線した子の event だけが入る）。親から send させたい場合だけ、それを公開する。
   公開の有無が宣言から読めること。`export receives` は読みにくいので別の形を探す
5. 自分が出す event の型（直和）

### B. 宣言（body の中）

1. 子 / resource の宣言。必ず名前を持つ（address になる）。任意の key（同一性の上書き）
2. 子の event を自分の inbox に流す配線。tag（inbox の直和の構成子）を指定する。配線した子に run は依存できない（静的エラー）ので、
   「配線した子」と「send する子」が見た目で区別できると望ましい
3. state の宣言（型と初期値）。書けるのは run だけ。読むのは宣言と run
4. 条件付きの宣言ブロック（条件が真の間だけ存在する）
5. 集合に対する宣言（要素ごとに子を作る。key は要素から計算）。式としては Map<Key, V> の値を持つ（各要素の最後の式）
6. export の印（子の出力、state、tool 値に付けられる）
7. run（1 つだけ）。`loop { … }` の省略形があると便利

### C. run の中（逐次）

1. inbox から受ける: 次の 1 件、溜まっている全件、条件に合う最初の 1 件（合わないものは残る）
2. 自分の event を出す
3. send できる子の inbox に送る
4. tool を呼んで結果を待つ（Fault は伝播）。Outcome をそのまま受ける形もある
5. pool（state、props、子の出力）が条件を満たすまで待つ。値が変わるたびに body をやり直す繰り返し（collectLatest）
6. state への書き込み
7. ブロックの間だけ存在する resource
8. 並行して複数の tool を待つ（全部 / 先に揃った方）。動的な個数の並列（要素ごとに key）
9. loop / for / break / match / try catch throw
10. run の末尾の finally（完走・失敗・cancel のどれでも走る）
11. run の中の局所変数は不変（let）。可変なものは state

### D. tool と純粋関数

1. tool の定義（引数、結果型、逐次の body）。意味論的には「event を 1 回出す component」の糖衣
2. tool 値: 定義に一部の引数を与えたもの（AI に渡す）
3. 純粋関数の定義
4. component の中に書く手続き（run の区間として inline に走り、state を書ける。値にはならない）

### E. 外部 component（provider が定義）

1. 名前と引数、出力、event 型、inbox 型を宣言する（Katari 側の型宣言）
2. 引数ごとの差し替えへの反応（restart / update / finish）、replace の禁止、再起動時の扱い、dispose の意味、を静的に宣言する

### F. 更新（patch）に伴う構文

1. migration: component の state の変換、run の位置の変換（label と locals）、inbox の message の変換、改名の対応（moved）
2. run の中の await 位置に名前を付けられること（migration と plan が参照する）

## 制約

- 全ての宣言は名前を持つ（address）。`_` は不可
- 宣言の集合と逐次コードは、見た目で区別できること
- 「配線した子に send しない」「send する子から event を受けない」が、できれば構文で自然に守られること
- keyword は少なく。既存言語の語彙（React、Kotlin、terraform）を借りる

## 書いてほしい例（意味は固定。構文だけ変える）

1. echo bot: discord の channel を宣言し、その message を購読して echo を返す
2. ターン制 bot: 溜まった message を全件取り、typing を出している間に推論して返信
3. ユーザーごとの常駐: 親は「誰が来たか」だけ見て users を更新し、要素ごとに Conversation を作る。Conversation は自分の分だけ購読する。30 日不在で消す
4. 承認: 人間に質問し、3 日の timeout と race。取り下げ時に finally で通知
5. PR パイプライン: branch は component と同じ寿命、PR は「レビュー中」の間だけ存在する条件付き宣言。run は PR を待ち、レビューを回し、merge を待つ
6. orchestrator: 計画を立て、task ごとに Worker を作り（task は props）、Worker の Done event を集める
7. 常駐 agent に send して、返事を state で読む（親は agent の inbox に送るので、agent の event は受けない）
8. 動的 attach: 生成した source を link し、人間の承認を挟む
9. 外部 component の宣言例: discord.channel（update できる引数）、pay.charge（finish、replace 禁止）
10. migration の例: state の型変更、run の位置の変更、改名
