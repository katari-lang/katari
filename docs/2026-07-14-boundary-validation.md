# 入力検証は境界で — call_error は call_agent 専用、acceptance 非合致は panic(escalation 統一の続き)

no-catch([docs/2026-07-14-ffi-no-catch.md](2026-07-14-ffi-no-catch.md))を拡張して確定させる。実行失敗
(body の throw/panic)は proxy のまま。加えて **入力の形式検証(引数が agent の宣言 input schema に
合致するか)を各境界で行い、非合致はそれぞれの境界のエラーにする**。owner の整理: 「mcp.serve /
webhook / AI委任は同一(外部への実行依頼)。呼び出しの形式検証だけ別物」。

## 1. 4-way の入力経路(それぞれ自分の検証・エラー)

- **i. 直接呼び出し** — 型システムが合致を保証。**runtime 検証なし**。
- **ii. AI / 動的呼び出し(`reflection.call_agent`)** — target の input schema を**事前検証** →
  非合致は `call_error`(catchable、reflection.ktr:50 が宣言済み)。今は tool 型 target のみ
  dispatchCallable が検証し、agent 型 target は acceptance surface 任せ = 非対称。call_agent が
  **全 target 種を事前検証**するよう揃える(agent 型でも call_error を catch できる)。
- **iii. mcp-serve / webhook** — 外部の不定入力。served agent の input schema を dispatch 前に
  **事前検証** → 非合致は **per-request の 400 系**(escalate せず、endpoint 生存)。今 tool 型 callable
  は dispatchCallable が per-request throw(mcp-reactor.ts:393 / webhook-reactor.ts:162)を出すが、
  **agent 型 served tool は検証されず acceptance surface に落ちて escalate → endpoint drop**(現バグ)。
  agent 型も事前検証して 400 にする。
- **iv. acceptance surface(`core-reactor.ts:180-208` onDelegate)** — 上流で全経路が検証済みなので
  ここに非合致が到達するのは**型システムの穴か genuine な欠陥(FFI handler の契約違反等)**のみ。
  よって `raiseThrow(call_error)` を **panic** にする(防御的・健全)。

## 2. なぜ panic が正しい(健全性の修正)

acceptance surface が `call_error`(= `prelude.throw`)を上げると、**throw effect を宣言していない
agent の境界に throw を注入**することになり、その agent の effect row の嘘になる(scout 確認:
served `mcp.tool[URL]` は `throw[server_error|auth_error]` で call_error を持たない。なのに境界で
call_error が上がる)。**panic は effect row と直交**する欠陥チャネルなので注入しても嘘にならない。
かつ、型付き直接呼び出しは原理的に非合致しないので、panic は純粋に防御的で実際には発火しない。
`value/validation.ts:1-7` のヘッダは既に「malformed argument を **panic** として弾く」と書いており、
実装が call_error に drift していた — panic 化はドキュメントの意図に戻す修正でもある。

## 3. 共有と局所の分割(共通化ではなく)

事前検証の**純粋な mechanism** だけを共有ヘルパにする:

```ts
// value/validation.ts 近傍。callable value の宣言 input schema に arg が合致するか(純粋)。
// schema は callableMetadata(value, ir)（interop-prims.ts:472）で解決 — reflection.get_metadata と同源。
function conformCallableArgument(value: Value, argument: Value | null, ir: IrSource):
  ConformFailure[] | null
```

**エラーの生成は各境界がローカルに**(policy): call_agent → `call_error`、mcp-serve → JSON-RPC の
invalid-params(400 相当)、webhook → HTTP 400 相当。共有するのは「schema に合致するか」の判定だけで、
「非合致をどう表現するか」は各境界の言葉。これは control flow を callback で括る共通化ではなく、
純粋述語の共有 + 局所的なエラー生成。

- `dispatchCallable`(dynamic-dispatch.ts)は tool 値を既に検証している。agent/closure 値の検証を
  「dispatchCallable に IR resolver を渡して一様化」するか「各境界が上のヘルパで事前検証」するかは
  実装判断。ただし**直接呼び出し(ii でない ordinary delegate)には事前検証を足さない**
  — 型システム任せ。dispatchCallable を全 agent 検証にすると直接呼び出しも巻き込むので、検証は
  **動的境界(call_agent / mcp-serve / webhook)側**に置く。

## 4. スキーマ解決の seam

reactor は served agent の input schema を `callableMetadata(value, ir)`(interop-prims.ts:472-499、
tool は `.inputSchema`、agent/closure は `locateCallable`→`.schema`)で得られる。serve listing は既に
`project-actor.ts:342` で `callableMetadata(entry.value, this.ir)` を呼んでいる(schema は turn の外で
actor が解決、mcp-reactor.ts:350 のコメント)。同じ ir seam で serveCall / deliver の事前検証を行う
(reactor に ir が無ければ、listing と同様 actor 側で解決して渡す)。

## 5. run コマンド引数も外部境界

`core-reactor.ts:180` のコメントは acceptance surface が「run command の JSON 引数」も検証すると言う。
acceptance を panic にするなら、**run-start API も entry agent の input schema に対し引数を検証して
400 を返す**べき(malformed な run 引数が panic で run を殺すのでなく、開始を弾く)。run.service が
既に検証しているか確認し、無ければ足す(mcp/webhook と同じ「外部境界は検証して弾く」規則)。

## 6. call_error の残る所在(stdlib 不変)

scout 確認: `throw[call_error]` を宣言するのは **`reflection.call_agent`(reflection.ktr:50)だけ**。
mcp tool / mcp.call / codegen 生成 binding は元々 call_error を持たない。よって **stdlib の型表面は
変わらない**(call_error は call_agent の row に残る)。変わるのは acceptance surface が call_error を
上げなくなる(→ panic)ことと、動的境界が事前検証で call_error/400 を出すこと。ランタイム消費者
`isCallError`/`callErrorMessageOf`(mcp-serve.ts:275-283)、facade.ts:333 は call_agent 経路として残る
か、mcp-serve の 400 生成に流用するか実装判断。

## 7. no-catch のテスト差し替え(このウェーブで確定)

no-catch のテストは「malformed request → endpoint drop」を pin していた。本ウェーブで正しい最終挙動に
差し替える:
- **malformed request(入力非合致)→ per-request 400、endpoint 生存**(mcp-serve / webhook)。
- **body の genuine な throw/panic → proxy(endpoint drop、resilience は tool を handler で包む)**。
- call_agent で agent 型 target を誤引数で呼ぶ → `call_error` を katari が catch できる、を pin。
- acceptance surface に非合致が到達したら panic、を（人工的な経路で）pin。

## 8. 受け入れ基準

- 全 runtime + port テスト green(差し替え済み)。挙動: malformed=400 / 実行失敗=proxy / 動的=call_error /
  直接=型保証 / 防御=panic。
- typecheck / lint clean。stdlib 型表面不変(676 compiler テスト green)。
- 触った箇所のコメントは why-文へ。`value/validation.ts` の doc drift 解消。
- adversarial review: (a) call_agent が agent 型 target の非合致で call_error を上げ catch 可能、
  (b) mcp-serve/webhook の malformed が 400 で endpoint 生存、(c) 実行失敗は依然 proxy で drop、
  (d) 直接呼び出しに余計な runtime 検証が入っていない、(e) acceptance surface の panic が effect row を
  破らない、を検証。
