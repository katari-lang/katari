# `region` — 構造化並行 nursery(fork / join / watch / cancel, v0.1.0, scrap-and-build)

`prelude.region` は **構造化並行(structured concurrency)の nursery** を、5 つの普通のエージェント値として
提供する。`region.provide` が単一入口・単一出口の scope を開き、その中で `region.fork` が子エージェント
(**fiber**)を並行に走らせ、`region.join` が 1 本を待ち、`region.cancel` が 1 本を畳み、`region.watch` は
fiber たちの escalation を「enclosing プログラムが handle できる位置」に湧き上がらせる **white hole** である。
5 操作はすべて runtime の `region` reactor(in-runtime scheduler、`time` と同じで FFI sidecar なし)に routing
される。

この設計は既存の 2 つの機構の掛け合わせである:

- **`mcp.provide` の scoped-provider 形(runST 形)**: caller が選んだ phantom marker を継続の row に mint し、
  自身の結果 row から discharge する。fiber は「その `provide` が走っている間だけ」存在する値であって、
  block を跨いで生き延びる値ではない。
- **`parallel`(固定配列の fork-join)**: 並行な子の集合。ただし `region` は fork と join を**分離**し、fork は
  ハンドルを即返して fiber は独立に走り続ける。

surface はこの 5 エージェントだけで、プログラムが触れる runtime 面はそれ以外に無い。したがって合成は
**型検査時に閉じている**(`katari check` 単独で「region を handle する義務」を検証できる)。実物は
`examples/playground/src/playground/region.ktr`、e2e は `e2e/tests/playground.e2e.test.ts` の
`playground.region.main`。

---

## 1. 動機 — なぜ multi-agent に nursery が要るか

AI orchestration は本質的に「複数の agent / task を同時に走らせ、結果を集め、途中で止め、途中の問い合わせに
答える」ワークロードである。素朴には次のプリミティブが欲しくなる:

- 動的な本数の子を spawn したい(`parallel for` は集合が既知で全部 await する固定形しか書けない)。
- 子を spawn しても**すぐ制御を返し**、あとで好きなものだけ join し、残りは cancel したい。
- 子が途中で「これを許可して」「この値をくれ」と**問い合わせ(escalation)**してきたら、それを enclosing の
  handler で受けて答えたい(AI の tool-call ループがまさにこの形)。
- そして最も重要な安全性: **どの子も、それを spawn した scope より長生きしてはならない**。scope を抜けたら
  走り続けている子は全部畳まれる。孤児 fiber を残さない。

これが構造化並行 nursery であり、`region` はそれを Katari の型システム(marker effect + row subtyping)と
runtime(reactor の callee-call lifecycle)にちょうど乗せたものである。

---

## 2. 型の物語 — scope marker で脱出を禁止、`E` で fiber effect を上限する

`prelude/region.ktr` の型は 2 つの不変条件を**型検査時に**担保する。

### 2.1 scope marker(脱出不能性)

```katari
effect scope                                          -- 組み込みの nullary phantom marker
type fiber[effect Scope, T] = agent never -> T with Scope

external agent provide[effect Scope, effect E, R, effect Eouter](
  continuation: agent (value: nursery[Scope, E]) -> R with Eouter | Scope,   -- 継続の row に Scope を mint
) -> R with Eouter from "region"                                             -- 自身の row から discharge
```

`scope` は **phantom marker effect**: 操作を名指さず、perform されず handle されず、lowering で消える。`provide`
はこの `Scope` を継続の row に敷き、**自身の結果 row からは引く**(runST 形)。`fork` / `join` / `watch` /
`cancel` はすべて `with Scope` で gate される。したがってこれらは「まだ `Scope` を運んでいる row の中でだけ」
型が付く — それは `provide` の継続だけである。fiber を `provide` の外へ返すと、引きずってきた `Scope` を
discharge する場所が無く、join する live な nursery も無い(**使用位置で型エラー**)。

`Scope` は `fiber[Scope, T]` の**effect row 位置**に載る(`data` phantom ではなく)。これにより `fiber[a, T]` は
`fiber[b, T]` の subtype に**ならない**(distinct marker 間で widen しない)。ある nursery の fiber を別の nursery
の `join` に渡せば型エラーになる。nursery を**ネストするときは marker を別々に宣言する**(module-local な
`effect` を per-nursery で宣言する。同じ marker を共有すると scope が merge し fiber が相互 join 可能になってしまう)。

### 2.2 nursery ハンドルは `Scope` と `E` を **invariant** に運ぶ

```katari
type nursery[effect Scope, effect E] =
  agent (gate: agent never -> unknown with Scope, bound: agent never -> unknown with E)
     -> {gate: agent never -> unknown with Scope, bound: agent never -> unknown with E}
```

`Scope` も `E` も**反変位置(引数)と共変位置(結果)の両方**に現れる。ハンドルを unify すると `Scope` と `E`
が `provide` の固定した値に**ぴったり**pin される。この exactness が二重に効く:

- `Scope`: `join` は nursery から `Scope` を回収し、fiber 側の scope が**それに一致すること**を要求する(上限
  かつ下限)。共変のみだと `join` が 2 scope の union を推論して mismatch を通してしまう。
- `E`: `fork` は `E` を「子が超えてはならない ceiling」として読み、`watch` は「まさにそれ」を re-emit する。
  だから `E` は widen も narrow もできない。

### 2.3 `E` — fiber-effect の上限

nursery は「その fiber たちが起こしてよい effect」を**あらかじめ** `provide` の第 2 型引数で固定する。`fork` は
子の effect が `E` の下に収まるときだけ受け付ける(effect subtyping。少なく起こす子は OK、多く起こす子は型
エラー)。`watch` は **`E` の全部**を re-emit する。したがって「`watch` の位置で `E` を覆う handler を置けば、
どの fiber が起こしうる request も覆える」— ceiling と white hole が合わさって **「region を handle する」を
totality 義務**にする(`katari check` だけで検証)。空 ceiling は `pure`(fiber が何も起こさない fan-out)。

---

## 3. white hole — `watch` が fiber の escalation を handler に湧き上がらせる

fiber の escalation は `fork` には surface しない(`fork` はハンドルを即返す)。surface するのは `watch` である。
`watch` の結果 row は `E | Scope`。`watch` の周りに(nursery ハンドルをまだ持っている位置に)installed した
`handler` が、fiber たちの request を捕まえる。`watch` は `never` を返す — 決して値を yield せず、ただ raise
するだけなので、resilience と termination は **`watch` の周りに合成する**(`time.watch` を `enough` throw で
止めるのと同じ)。`region.ktr` の `subscribe` がこの形の実例で、handler は 4 メッセージ受けたら `enough` を
throw して nursery を畳む。

**合成**: handler の中から新しい fiber を `fork` できる(handler body の row は継続の row を継ぐので `Scope` を
運ぶ)。`subscribe` は最初のメッセージで 2 本目の emitter を同じ nursery に fork する — white hole の中から
spawn する fiber。

---

## 4. 実装 — `region` reactor(`ExternalCallReactor` の subclass)

`typescript/runtime/src/runtime/actor/region-reactor.ts`。base class `ExternalCallReactor` が「callee を呼ぶ
call の lifecycle(inner delegation、escalation の relay bridge、cancel cascade `terminateChildren`、durable
extension の encode/decode)」を提供し、`region` はそこに 5 variant を足す。compiled な `prelude.region.*`
external は qualified 名で wire に載り、`openPayload` の 1 箇所で振り分ける。

### 4.1 `provide` — scoped provider

`provide` は scope 識別子(open 時に mint する in-runtime identity)を register し、その identity を運ぶ
`nursery` ハンドル値を mint し、**継続を 1 本の inner delegation**として `{ value: nursery }` で dispatch する。
call 全体は継続の outcome で settle する(serve / webhook の `innerOutcomeAsCompletion` テンプレ)。settle か
cancel が scope を閉じる。`mcp.provide` と違い listing(列挙する server)も transport も無いので、継続は
post-commit の最初の turn で**直接** dispatch される(side の `listTools` delegation を待たない)。

> **nursery が継続に conform するか(wave 2 の open question, 解決済み)**: nursery の runtime 値は record
> `{$katari_region_scope}` だが、継続の宣言入力型は phantom **agent** 型 `nursery[Scope, E]`。この内部
> dispatch は `dispatchCallable` → `openInnerDelegation` で**動的入力境界の acceptance pre-check を通らない**
> ので、record は construction により conform し、境界で mismatch しない(`mcp.provide` が同型の問題を回避する
> のと**同じ扱い**)。compiled program で end-to-end に検証済み(§7)— **修正不要**。

### 4.2 `fork` — fiber = detached delegation

`fork` は独立の call だが、開始する fiber は fork call の子**ではない**: fork は task を**nursery の PROVIDE
call の inner delegation**として開き、その場で `fiber` ハンドル値で自身を settle する。fiber を provide に
parenting することで構造化並行の物語が base からタダで手に入る:

- fiber の escalation は provide 経由で enclosing に relay UP される(base の relay bridge)。
- fiber は provide の cancel cascade(`terminateChildren`)で、block が返るときに畳まれる — **どの fiber も
  nursery より長生きしない**。

join される前に settle した fiber は、その outcome が provide 上の durable `fiberBuffer` に buffer される。

### 4.3 `join` — fan-out

`join` は 1 本の fiber を待ち、settle した値を返す。fiber ハンドルで routing される(ハンドルが spawn した
nursery の scope を名指す。だからネストした同一 marker scope 下でも fiber は**自分の nursery で**待たれる)。

- 既に settle 済み: outcome は `fiberBuffer` にある → 取り出して(single-consumer)即 settle。fiber の結果
  リソース(blob / scope)は provide instance から join の instance へ移し替え、join の `delegateAck` が join の
  caller へ再 own する。
- まだ running: call を held-open して **waiter**(`Map<fiberId, joinDelegation>`)を park。fiber が後で着地した
  ときに `bufferFiberOutcome` が buffer せず直接この join を settle する。
- buffer にも running にも無い: 既に join 済み(single-consumer)/ malformed / restart で失われた等。checker が
  ハンドルの scope を live nursery に pin しているので、この runtime 状態に至るのは engine 不変条件の破れ →
  **panic**(join の row は throw を宣言せず、region に error sum も無い。dead-scope fork と同じ backstop)。

`region.ktr` の `fan_out` が実例: 3 本 fork して 3 本 join、`[4,9,16]`。`parallel for` との違いは §6。

### 4.4 `cancel`

`cancel` は 1 本の fiber を早期に畳む。fiber の inner delegation に単一の `terminate` を送る(nursery 全体の
`terminateChildren` cascade の**単一 fiber 版**)。cancel された fiber は join 可能な outcome を持たない(その後
join すると panic、double-join と対称)。settle 済み(buffered)/ gone の fiber の cancel は idempotent な no-op で
成功し、buffer 済み outcome を落として「fiber は unknown」という post-condition を race 非依存に保つ。cancel と
join は排他的意図(「要らない」vs「結果を待つ」)なので、running fiber に park していた join を cancel が着地
すると、その join は panic される。

### 4.5 white hole の実装 — mailbox re-emit

fiber の escalation は通常なら provide 経由で relay UP される。`watch` はそれを **intercept** する:
`onEscalate` が fiber の ask を認識し、nursery の durable **mailbox** に holds し、**watch call 自身の
delegation の下で** re-emit する(`relayAskUnder`)。だから ask は provide の上ではなく watch の caller(=
handler)に surface する。handler の answer は同じ bridge を降りて fiber に戻る(`onEscalateAck`)。re-emission は
**FIFO かつ serial**(held-open な watch call は同時に 1 件だけ運ぶ。busy 中に来た escalation は mailbox に溜まり
1 件ずつ drain)。

watch が**無い** nursery は後方互換の path を保つ: mailboxed な escalation は global quiescence(`onQuiesce`)で
provide 経由で run root に flush UP される。「watch 有無」は quiescence で振り分ける — 登録するはずの watch が
あればまだ継続が dispatch 中(非 quiescent)なので、quiescence でなお mailbox が埋まっているのは genuinely
watch-less な nursery。この 1 点で「late watch との race」が起きない。

### 4.6 所有権(delegation graph と cascade)

nursery の所有関係は base の inner-delegation graph に乗る。fiber は provide の inner delegation なので、

- fiber の**リソースの再 own**: fiber が settle すると結果リソースは provide instance に再 own され、buffer に
  残る。join が取ると provide → join → join の caller へ移る。un-join の buffered outcome は provide の drop で
  reclaim(leak なし)。
- **escalation が運ぶ blob**: `onEscalate` は ask の carried 値を provide instance に再 own してから mailbox に
  積む。parked なリソースが commit と provide の drop を跨いで生き延びる(§5 参照)。
- **region 脱出の cascade**: block が返る(または `enough` のような throw で脱出する)と provide call が畳まれ、
  `terminateChildren` が全 fiber を畳む。孤児を残さない。

### 4.7 durability

`provide` は endpoint payload(scope id + まだ stored な継続 + `fiberBuffer` + mailbox + inner-delegation
bridges)を persist し、restart を完全に生き延びる(`webhook` / `time` と同じ、外部プロセスが無いので reconcile
する相手がいない)。scope を再 register し、継続と running fiber を durable core work として resume する。`fork`
は (task + argument) の再 dispatch を persist し reload で単に再 spawn(inner delegation を開くだけなので再実行
安全)。`join` は (scope + fiber) を persist し、reload で reloaded buffer / running set に対して再 drain / 再
park。いずれも public capability token を mint しない(nursery に inbound URL は無い)。

---

## 5. blob を white hole 経由で運ぶ — 現状の挙動(wave 6 申し送り)

fiber が blob(`file`)付きの request を `watch` 経由で投げ、handler がその blob を読むケースを検証した
(`file.from_base64` で "hello" を作り、fiber が `on_file(payload = it)` を perform、white hole の handler が
`file.read_base64` で読む):

- **結果: READABLE**。handler は blob の中身を正しく読める。理由は §4.6 の再 own である — `onEscalate` が
  carried 値の blob を provide instance に再 own し、nursery が live な間 blob は生き続ける。blob read は id 引き
  で ownership を検査しない(存在すれば読める)ので、handler の位置(watch は provide の中)で blob は gone に
  ならない。MVP(text メッセージ)はもちろん、blob 付きでも fiber → handler 方向は**壊れていない**。

**未検証の縁(将来対処)**: (a) handler が answer に blob を**載せて返す**方向(escalateAck の relay 降下が
blob を運ぶか)、(b) escalation が mailbox に**未応答で溜まったまま restart** した場合の blob 寿命(mailbox 上の
blob ref は persist され provide instance に再 own されているので健全なはずだが、未検証)。現状は fiber → handler
方向のみ検証済みとして記録する。

---

## 6. `parallel for` との違い・合成

`parallel for` は**固定形の fork-join**: 要素ごとに 1 子、閉じ括弧で全部 join、結果は順序どおり。集合が既知で
全結果を await するときの正しい道具。`region` は 2 つの半分を**分離**する: `fork` はハンドルを即返し fiber は
独立に走る。だから (1) 動的本数を fork、(2) 欲しいものだけ join(残りは cancel)、(3) handler の中からさらに
spawn、(4) fiber を `watch` 経由で escalate、ができる。`region.ktr` の `fan_out` は両者の重なり(同じ
`[4,9,16]` を `parallel_squares` でも計算して対比)、`subscribe` は `region` にしか書けない形(white hole)。

---

## 7. end-to-end 検証(この wave)

- **型**: `examples/playground` は `katari check` で 29 module no errors(region.ktr 込み)。
- **compile → run**: compiled IR(`katari build`)を runtime(`ProjectActor` + in-memory persistence)で実行し、
  `playground.region.fan_out` → `[4,9,16]`、`parallel_squares` → `[4,9,16]`、`subscribe` →
  `"subscription saw four messages across two emitters"`、`main` → 全部を結合した 1 行を確認。nursery が継続に
  conform し、white hole・handler からの fork・cancel cascade まで通しで動く。
- **e2e**: `e2e/tests/playground.e2e.test.ts` に `playground.region.main` を追加(docker + real runtime server
  で、CLI compile → deploy → run の wire 互換ネット)。

補足の作法上の発見: `file` は予約 **型キーワード**なので、`file.gone` / `file.malformed_base64` を型位置で
書けない(`import { type gone, type malformed_base64 } from prelude.file` で名前を持ち込む)。区分けは軽微だが、
将来 stdlib の file error を型位置で使う例が増えたら import が要ることを覚えておく。

---

## 8. AI 統合の設計(out-of-repo `katari-packages/ai`)

**この repo にはコードを書かない**(ai module は out-of-repo)。ここでは region がどう AI turn を支えるかの設計を
記述する。核心は「AI にとって fork / join / cancel は native tool に見え、その裏側は region がそのまま担う」。

- **`ai.infer` が `region.provide` を内蔵する**。1 回の AI orchestration(モデルとの多 turn 対話)を 1 つの
  nursery の中で走らせる。scope marker は ai module 自前の module-local `effect`(例 `ai.turn`)。ceiling `E` は
  「その推論に渡した tool 群の effect の union」。
- **tool 名の解決 → `region.fork` に渡す**。AI が「この tool をこの引数で」と返したら、ai module は
  `reflection.call_agent` の解決機構(tool 名 → agent 値)を**再利用**して agent を引き当て、`region.fork` で
  fiber として spawn する。複数 tool-call を 1 turn で返してきたら**複数 fork**(並行実行)。AI からは「tool を
  呼んだ」に見えるが、裏は detached fiber。
- **fiber の request を `watch` で受けて AI turn に注入**。tool(fiber)が実行中に escalation(承認要求、部分
  結果、進捗)を起こしたら、それは white hole 経由で ai module の handler に湧き上がる。handler はそれを次の AI
  turn の context に注入する(「tool X がこれを尋ねている」)。`join` は tool の最終結果をモデルに返す
  observation にする。
- **AI からは fork / join / cancel が native tool に見える**。モデルが「この tool を止めて」と言えば
  `region.cancel`、「全部の結果を待って」は `join` の束、「これも並行で」は追加 `fork`。構造化並行の安全性
  (turn を抜けたら走っている tool は全部畳まれる = 孤児 tool を残さない)は region がそのまま供給する。
- **なぜ region がちょうど良いか**: AI tool ループは本質的に「動的本数の子を spawn し、途中の問い合わせに答え、
  好きなものを待ち/止め、turn の scope で全部畳む」— それは nursery そのもの。ai module は**新しい runtime 面を
  作らず**、region の 5 エージェントと reflection の解決機構を合成するだけでよい(owner 原則: 一般機構を作り、
  具体はデータ/合成に寄せる)。

---

## 9. これで v0.1.0 の region は「end-to-end で動く」か

**動く**。型(`katari check`)、compile(`katari build`)、runtime 実行(fan-out・white hole・handler からの
fork・cancel cascade)を compiled program で通しで確認し、e2e(docker + real server)も追加した。wave 2 の
open question(nursery conform)は「修正不要 — 内部 dispatch が acceptance 境界を通らないので construction で
conform」と確定。blob-through-watch は fiber → handler 方向が readable と確認(未検証の縁は §5)。残る穴:
answer に載る blob と未応答 mailbox の restart 寿命(§5)、AI 統合の実コード(out-of-repo, §8)。
