# reactor は callee の失敗を catch しない — 全 reactor 一様に proxy する(rebuild control-flow、escalation 統一)

ゴール: **external-call reactor の「失敗を分類して inner call を fail させる」枝を完全削除し、
callee のあらゆる escalate を(ffi/webhook/mcp/time すべてで)一様に上へ proxy する**。owner の決定
(Option C 全面): runtime(reactor)は一切 catch しない。callee の失敗は throw も panic も上へ
unwind し、catch したければ **katari の handler を直前に挟む**。挟まれていなければ親から cancel される
のが適切。これは owner の広い原則「katari は言語として表現力が十分 → オーケストレーション/error
handling/retry は katari 側でカスタムする。runtime のおせっかい(代替可能)機能は消す」の適用であり、
ffi の at-most-once(retry を katari でカスタムさせる)と同じ理由。

**effect-handler の理想形**: reactor は「何も intercept せず全て proxy」— gating も boolean も override も
無い純粋 proxy。ffi 層だけでなく webhook/mcp/time の inner-delegation 失敗も一様に proxy になる。

**明示された帰結(受諾済み)**: webhook の delivery / mcp の `tools/call` で served な callback/tool が
handler 無しで throw/panic すると、その escalate は上へ proxy して endpoint が cancel される(1 つの
バグった tool が server 全体を落とす)。per-request の resilience が欲しい served agent は**自分の body を
handler で包んで throw を error 値に変える**。resilience の責任は runtime から katari(agent 作者)へ移る。
これは意図した仕様変更。

## 1. 挙動の変更(仕様)

- callee(ffi handler が `context.call` で開いた inner delegation)が panic / throw を上げたとき、
  現状は external-call reactor がそれを **inner call の失敗**として settle し、JS handler の
  `await context.call()` が reject する(JS の try/catch が拾える)。**これを削除する**。
- 変更後: callee の escalate は**一様に上へ proxy** される(既存の汎用 proxy 経路、
  `external-call-reactor.ts:442-456)`。ffi handler の `context.call()` は **reject しない**
  — callee の失敗は ffi handler の失敗として上へ unwind し、それを catch した層(katari の
  throw-handler)or run root に達する。ffi handler の実行中処理は**落とさない**: 上位が unwind を
  処理して terminate cascade を流すまで**待つ**(runtime 全体の「失敗は上へ、cancel は下へ」に一致)。
- 死んだ callee(panic した B)は、その escalate を proxy した ffi handler H が上位の処理で
  terminate されると、H の `onTerminate` → `terminateChildren` の cascade で落ちる。よって現状の
  「死んだ callee を明示 terminate する」step(430-439)は cascade が代替する — **leak しない**
  (B が running のまま残るのは cancel が届くまでの過渡状態で、これは意図した挙動)。実装後、
  この経路(callee panic → 上位 catch / run fail → cascade が B まで届く)をテストで pin する。

## 2. 削除するコード

- `external-call-reactor.ts` `onEscalate`(402-457): `isFailureRequest(event.ask.request)` の分岐
  (419-441)を**全 reactor で**削除し、**else の proxy 経路を onEscalate の本体**にする(gating も
  per-reactor override も無し)。entry guards(raiser 消失 406-408、call winding-down 415-417)は
  汎用なので残す。この結果、webhook/mcp/time の inner-delegation 失敗も一様に proxy になる。
- 失敗 catch 専用ヘルパ `panicMessageOf`(909-915)、`innerThrowOf`(920-926)、および
  `stageInnerDelivery` の `error`/`throw` 消費のうち callee-escalate 由来の分だけ削除
  (**local な resolveInnerCall の失敗**由来 = bad dispatch / non-callable value は別経路 —
  ffi-reactor 159/247/253 — なので**残す**: それは callee の escalate ではなく、その場の
  dispatch 失敗で、handler が扱える inner-call error のまま)。
- `isFailureRequest` の import(external-call-reactor.ts:41)を削除。これで escalation-flow の
  ffi 層はグローバル分類器を参照しなくなる(consumer (iii) が消える)。

## 3. port の契約(typescript/port)

- `context.call` は callee の失敗で reject しなくなる。`index.ts` の `delegateResult` 処理で
  callee escalate 由来の `throw`→`KatariThrowError`、`error`→`KatariCallError` は callee 失敗に対して
  **到達不能**になる。`KatariThrowError` の **inner-reject 経路のみ削除**(callee escalate 由来の
  throw→reject)— **クラスは残す**:`katari.throw`(ハンドラ自身の outer な typed throw)と dispatch catch
  がそれを使い続ける(outer-call の throw reply は不変)。実装確定: クラス削除は outer throw を壊すので
  **narrowing であって class 削除ではない**。`KatariCallError` は **local な bad-dispatch**(resolveInnerCall
  失敗)と、動的な context.call の入力非合致(境界検証、`2026-07-14-boundary-validation.md`)で produce され
  続けるので**残す**が、docstring から「callee panicked/threw → rejects」を外し、「callee の EXECUTION 失敗は
  上へ unwind する(catch は katari 側)/ この呼び出し自体は入力非合致(catchable)かキャンセルでのみ
  reject」に改める。`cancelled`→`KatariCancelledError` は不変。
- `InProcessFfiTransport`(external/runner.ts 257-275)の対応する mirror も同様に整理。wire の
  `DelegateOutcome`(result | throw | error | cancelled)は **outer call の reply では不変**
  (`throw`/`error` は外側の completion 経路で使う) — 変わるのは inner `delegateResult` の producer
  だけ。sidecar-protocol の型は据え置き。

## 4. テストの書き換え

pin されていた挙動を新契約に合わせて書き換える(消すのではなく、新契約を pin し直す):
- `ffi-delegation.test.ts` 196-211「callee panic → handler が catch → fallback」→
  「callee panic は JS handler で catch できず run root へ proxy して run を fail させる(katari の
  panic は runtime の失敗チャネル)」。
- 213-218「uncaught inner failure → run fail」→ proxy-up 経由でも run が fail することを pin
  (outcome 同じ、経路が proxy)。
- `ffi-throw.test.ts` 214-232「callee throw → handler が FfiThrow で catch」→「callee の
  `prelude.throw` は JS で catch されず上へ proxy、**katari の throw-handler が catch できる**」
  (ffi handler の外側 or 上位の katari agent に throw-handler を置くテストに)。
- 234-241「uncaught inner throw rethrows(payload 温存)」→ proxy-up で payload が上位まで温存され
  未 catch なら run を fail させることを pin。
- **`mcp-serve.test.ts` 335-362**(throwする tool が `{kind:"throw"}` をその呼び出しに返し endpoint
  生存)→「served tool が handler 無しで throw → escalate が上へ proxy → serve call が cancel され
  endpoint が落ちる」。resilience が要る served tool は自分で handler を挟む例も 1 本追加してよい
  (tool body を `handle throw {...}` で包み error 値を返す → endpoint 生存)。
- **`webhook-reactor.test.ts`** / **`time-reactor.test.ts`**: delivery/tick の callee 失敗が
  proxy して call/run を fail させる新挙動に合わせる(time は既に run root で回るので現状 pass の
  可能性が高いが、経路が proxy になることを明示)。
- **残すべき invariant**(触らない): ffi-delegation 176-194(non-callable value = local
  resolveInnerCall、handler が catch — 挙動不変)、237-259(user-facing request の proxy — 生き残る
  汎用経路)、261-281(held completion)、298-318(cancel cascade)、ffi-throw の outer-call arms
  186-212。
- 新規: callee panic → 上位 katari の throw/panic 未 handle → run fail、かつ ffi handler の子
  (別 inner call)が cascade で落ちること(死んだ callee の cleanup を cascade が担う)を pin。

## 5. 受け入れ基準

- 全 runtime テスト green(書き換えた 4 本 + 新規 + 不変 invariant)。port テストも。
- 挙動変更は §1 の通り(callee 失敗が JS で catch 不能になる)— これは意図した仕様変更。
- `docs/2026-07-03-ffi-inner-delegation.md` の §「Reactor design」escalations 節と「The port,
  redesigned」を新契約に更新(callee 失敗は proxy、KatariThrowError 廃止、catch は katari)。
- typecheck / lint clean。純減を見込む(分岐 + 2 helper + port クラス + wire 消費の削除)。
- adversarial review: 死んだ callee が cascade で必ず落ちること(leak しない)、local bad-dispatch の
  inner-call error が**残っている**こと、outer-call の throw/error reply 経路が無傷なこと、
  held-completion / cancel cascade が無傷なことを検証。

## 6. スコープ外(別ウェーブ)

base(reactor.ts:238 send)が `isUserFacingRequest` で durable row を開く分類 — これを「api root の
open 決定に従う」形へ移すのは crash-window / turn=1-atomic-tx の機微があり、別途慎重に設計する
(escalation 統一の Part B)。本ウェーブは reactor の catch 削除(全 reactor 一様 proxy)に集中する。
`isFailureRequest` は本ウェーブで external-call-reactor から消えるが、api root(local 判定)と
durable read 経路には残る。
