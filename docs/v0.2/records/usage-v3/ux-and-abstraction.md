---
title: v3 評価 — UX と抽象の妥当性
description: v3 基底を初見の読者の視点で読み、概念を数え、借用元とのずれを挙げ、より少ない概念で同じ usage が書ける案を探す
---

対象は `../2026-10-02-spec-base-v3.md`。ドメイン別の usage は他の評価に任せ、ここでは言語全体の読みやすさと抽象の形だけを見る。

## 1. 初見の読者として読む

前提: React、async/await、terraform は知っている。Katari は知らない。

### 3 文で説明できるか

できる。核はこの 3 文に収まる。

```
1. component は React のコンポーネント。props と state から子（resource と子 component）を宣言し、消えた宣言は dispose される
2. 各 component は 1 本の loop（Kotlin の coroutine）を持つ。そこだけが state を書き、tool（async 関数）を await し、channel から event を受ける
3. 宣言には住所があり、terraform のようにデプロイの差分を plan / apply する
```

つまずくのは、この 3 文の外にある周辺の規則である。

### つまずく箇所

| 箇所 | 何に見えるか | 対処 |
|---|---|---|
| §1.1 `Component(B) ≅ (B ⇒ Void) ⇒ Void`、middleware、継続 | CPS の用語。React の読者には不要 | 本文から外し、形式化の付録に置く。本文は「`use x = M(args)` は子を宣言し、x はその export。x を使う宣言は x が揃うまで待つ」だけでよい |
| §1.4 address と DAG が別の構造 | 2 つの木があるように読める | 例を 1 つ置く（`use a` を消しても `b` は残る、依存だけ変わる） |
| `pool` / `member` | 既知の対応物が無い | §2 で代替案を出す |
| `self` と「全 export の後」 | 規則が突然現れる | `member` が無くなれば消える |
| `with r = kind(args) { … }`（run 内）と `use r = kind(args)`（body） | 同じことの 2 つの綴り | 1 つの keyword にする（§2） |
| `run { … }` と `loop { … }` の糖衣 | 2 つ覚える | 仕様本文は `run` だけにし、`loop` は 1 行の注記 |
| Data / Type、「state は Data」「channel は Data だけ」 | 型の階層に見える | 「handle は serialize できない。永続化されるもの（state、channel）には入らない」と 1 文で説明する |
| `when` は接頭辞を作らず `for` は作る | 覚える規則 | 「`for` は key ごとに別の住所」で足りる。`when` の注記は address の節だけに |
| 「tool は use できない」 | なぜか分からない | 「tool は関数で、呼ぶのは run の中。宣言は構造を書く場所」と理由を書く。導出データの書き方（§4 (e)）を直後に示す |
| `Reply(ch, persona, _)` の `_` | 部分適用の綴り | 注記で足りる |
| `await sig` | 何が待てるのか不明 | 型で限定する（§6） |

## 2. 概念の数

### 宣言（body）

`use`、`state`、`pool`、`member`、`when`、`for`、`run`（`loop`）、修飾子 `export`、`key` — 7 + 2。

### top-level

`component`、`tool`、`fn` — 3。

### run の中の文

`let` / `await` / `await try`、`<-`、`with`、`par` / `race`、`loop` / `for` / `break`、`var`、`match`、`try` / `catch` / `throw` — 普通の言語のもので、数えない。

### 型

`Component(B)`、`Pool<B>` / `Admit<B>`、`SendChannel<T>` / `ReceiveChannel<T>`、`Outcome<R>` / `Fault`、`~>`（tool）、`Definition<I>`、Data / Type の kind。

### 規則

address、依存 DAG、`key`、`when` の接頭辞、state は Data、単一書き手、await 境界で commit、継続は揃うまで待つ、`self` は export の後、export は top-level のみ、Pool の層化、launch 禁止、tool は use 不可、run の読みは現在値、`let` で固定、Fault の伝播、構造化 cancel、再起動契約、patch の規則。約 20。

### 削れるもの

**pool / member / self（3 つ）→ `for` を式にする。**
pool の用途は「子の handle を集めて他所から読む」で、ほぼ全て「親が自分で作った子を集める」形。`for` が iteration の束縛を集めて返せば足りる。

```
use teams = for spec in specs key spec.name { use t = Team(slack, spec); t }     teams : Map<Text, TeamHandle>（signal）
for t in tickets key t.id { use triage = Triage(model, t, teams) }
```

- 消えるもの: `pool`、`member`、`self`、Pool の層化の規則、`Admit<B>`
- 書けなくなるもの: 木の離れた場所から共通の registry に自分を登録する形。これは所有者の所へ `for` を持ち上げて書く（terraform で resource を所有場所に書くのと同じ規律）
- channel では代替できない。channel は Data しか運ばず、pool は handle を運ぶため

**`channels<K, T>`** は primitive でなくなる。`for` が式になれば、key ごとに `channel<T>()` を作って集める stdlib component で書ける。

**`with` と `use`** は 1 つの keyword にする。body の `use r = …` は宣言の寿命、run の中の `use r = … { … }` はブロックの寿命。意味は「宣言した間だけ存在する」で同じ。

**`run` / `loop`** は仕様本文では `run` だけにする。

残る宣言は `use`、`state`、`when`、`for`、`run` と修飾子 `export` / `key` の 5 + 2。

## 3. 借用元とのずれ

| 借用 | ずれ | 対処 |
|---|---|---|
| React の state | React は render とハンドラの closure から読む。Katari は render では signal、run では現在値。書き込みは `setState` ではなく `s <- v` | Svelte の store（`$s = v`）に近い。名前は state のままでよいが、「run の中では読んだ時点の値」を React の読者向けに 1 文で書く |
| React の unmount | React の unmount は安い。Katari の dispose は外部の resource を片付ける（terraform の destroy） | 「宣言が消える = destroy」を最初に言う。React の読者はここで一番驚く |
| React の key | React では list の中だけ。Katari は `use … key k` でも使える | 「同一性を上書きする」と説明すれば足りる |
| React の継続（x が揃うまで待つ） | React には無い（Suspense に近い） | 「resource の出力が揃うまで、それを使う宣言は保留される」。terraform の依存と同じなので terraform の言葉で説明する |
| Kotlin の structured concurrency | Kotlin は scope の中で `launch` できる。Katari は不可 | 「並行するものは全て住所を持つ子」と理由を書く。構造化並行性の名前は正しい |
| Kotlin の Channel | Kotlin の既定は容量 0（rendezvous）で、メモリ上。Katari の channel は永続化され、容量が未定義 | 容量を定める（§6）。永続化される点は Kotlin より SQS に近いので、「durable な Channel」と最初に言う |
| Kotlin の suspend fun | 一致。Katari は schema を持つ点が追加 | なし |
| actor | actor は mailbox が 1 つ。Katari は channel をいくつでも持ち、props も受ける | 「loop だけが state を書く」という本質は一致。mailbox が複数なのは問題ない |
| terraform の address / plan / moved | 一致 | なし |
| terraform の resource | terraform に run は無い | なし |

## 4. 直感性の検証

**(a) 親の props が変わったとき、子の run は何を見るか。**
次に読んだとき新しい値。`let` に写した値は変わらない。Kotlin の `StateFlow.value` と同じで自然。
ただし基底は「Katari で書いた component の params が update 可能か」を書いていない。kind の `updatable` は外部 kind の宣言で、Katari の component には適用されていない。**Katari の component の params は全て update 可能で、run は続行する**、と明記が要る。これが無いと「props が変わると子が作り直され run が最初から走る」と読める。

**(b) 子を消したとき、子の run が await 中の tool はどうなるか。**
宣言が消える → run が cancel → await 中の tool と `with` の resource が cascade で dispose。cancel は await 点でのみ起きるので、sync 区間の途中で止まることは無い。構造化並行性そのもので自然。

**(c) 2 つの子が同じ channel に send したとき、順序は。**
送信は transition（await 境界の commit）なので、runtime が直列化した transition の順。同じ送り手の中では FIFO。基底に書かれていない。明記が要る。

**(d) run が完了した（loop を抜けた）component は何をしているか。**
宣言されている限り生きている。state はそのまま、宣言は render され続ける。「終わった」ことを親に伝える手段は、export した state を書くか、親から渡された channel に send するか。自然だが、「component に戻り値は無い」と最初に言わないと探す。

**(e) 導出データ `use x = fetchUsers(groupId)` はどう書くか。**
書けない。state と run で書く。

```
state users: List<User> = []
run {
  for await g in groupId {              groupId が変わるたびに。前の fetch は cancel
    users <- await fetchUsers(g)
  }
}
```

`for await x in sig` は基底に無い。基底の `await sig` は「定義される / 真になるまで」で、**変化を待つ手段が無い**。長い loop が props の変化に反応するには、これが要る。Kotlin の `collectLatest` に相当。
導出データは頻出なので、上を stdlib の component にして `use users = derived(fetchUsers, groupId)` と書けるようにする。

**(f) state を 2 つの場所から変えたいときはどう書くか。**
所有者が channel を持ち、2 つの場所に send 側を渡し、loop で受けて書く。

```
use cmds = channel<Cmd>()
run { loop { match await cmds.receive() { Inc => n <- n + 1, Reset => n <- 0 } } }
use a = Child(cmds.send)
use b = Child(cmds.send)
```

actor のコマンドパターンで、一度知れば自然。React の `setCount` を下に渡す形より 3 行長い。この定型は多いので、
`state n = 0 with updates` のように state が自分の `updates: SendChannel<T → T>` を持ち、所有者の run が await 境界で順に適用する糖衣を置く案がある。単一書き手（機構としては所有者の run が書く）は保たれるが、「誰が n を変えるか」が send 側の受け渡しに散るので、既定にはしない。

## 5. より少ない概念の案

| 案 | 内容 | メリット | デメリット |
|---|---|---|---|
| A. `for` を式にする | iteration の束縛を集めて返す | pool / member / self / 層化 / `channels` primitive が消える | 離れた場所からの登録が書けない（持ち上げで書く） |
| B. `with` を `use` にする | run の中の `use r = … { … }` | keyword が 1 つ減る | run 内の `use` の寿命がブロックであることを 1 文で言う必要 |
| C. state と channel を 1 つにする | state を「最新値だけ残る channel」にする | 型が 1 つ減る | Kotlin が StateFlow と Channel を分けている理由（最新値 vs 全件）がそのまま当たる。混乱する |
| D. `when` を無くし `for` だけにする | `for _ in (if c then [()] else [])` | 宣言が 1 つ減る | 読めない |
| E. `run` を無くし、逐次は全て子 component にする | component に run は無く、`use j = Job(args)` | 「component = 宣言だけ」になる | state を書く場所が無くなる。Job が state を書くには closure か setter が要り、元に戻る |
| F. `fn` を無くし、await の無い `tool` を宣言から呼べるようにする | 等級を推論 | keyword が 1 つ減る | 「宣言から呼べるか」を等級で決めることになり、第 2 版の tool の等級が戻る |

A と B を推す。C〜F は退ける。

## 6. 仕様の文章の問題

- **Katari component の params の update**: 未定義。全 params が update 可能で run は続行、と書く
- **channel の容量**: 未定義。Kotlin の既定（0）だと親の loop が子の受信まで止まり、外部 event 源の buffer も成り立たない。既定は無制限（durable）、`channel<T>(capacity = n)` で制限、と書く
- **channel の送信順**: 未定義（§4 (c)）
- **channel の所有者が dispose されたときの未消費分**: 未定義。捨てる、と書く（それが嫌なら所有者を上に置く）
- **`await sig` の型**: 「定義される / 真になる」が何の型に適用されるか未定義。`Option<T>` なら Some を待って T を返す、`Bool` なら真を待つ、それ以外は型エラー、と書く。変化を待つ `for await x in sig` を足す
- **run の中の未処理の Fault**: 未定義。run は止まり、component は faulted として trace / plan に出る。親が知るには export した state に書いておく、と書く
- **run は 1 つ**: 2 つ書いたときのエラーと、`break` で loop を抜けた後の扱い（§4 (d)）を書く
- **run の位置の label**: `let` の名前、loop の反復 key、`with` の区間。第 2 版の規則を参照する
- **`self`**: `member` にしか使われていない。案 A を採れば削除
- **`export` できるもの**: 「channel の send 側 / receive 側」が、子から親へ send 側を export して親が送る形（props 的）と、親の channel の send 側を子に渡す形（callback 的）の両方を含むことを例で示す
- **tool 値の再評価**: 宣言の中の `Reply(ch, persona, _)` は signal 式なので `persona` が変われば再評価され、それを受け取る Katari component は update される。run の `let` に写した tool 値は固定。この 2 行を §3.2 に足す
- **§0 の「作用は外部にある」**: `s <- v` は作用に見える。「作用 = 外部への影響」と限定するか、文を変える
- **正典例 A の `ui.banner`**: 未定義の kind。注記で足りる
- **正典例 C**: `human.ask` が tool（結果を返す）になった。第 2 版では resource（取り下げは dispose）。tool の cancel = 葉の dispose なので整合するが、「tool を cancel すると葉に dispose が届く」を §3.2 に書く
