# escalation は一様 — 全部 row にする、区別は leaf と handler だけ(rebuild control-flow)

owner の原則: **escalation は一様なもの。失敗(panic/throw)も control escape も user-facing request も
同じ経路を通り、共通経路(base Reactor / relay / 永続化)は一切区別しない。区別は (a) raise する leaf と
(b) catch する handler(user の `handle`、および terminal handler の api reactor)でのみ行う。** throw は
「ただの escalation」で、api reactor が検知したら run を cancel する、それだけ。base で分類してはいけない。

今: base `send`(reactor.ts:235-251)は `isUserFacingRequest` の時だけ durable row を開く。panic/throw は
`raisePanic`/`raiseThrow` が `send` を bypass して row を持たない。→ **全 escalate を row にする**。
escalations テーブルが「起きた escalation 全部」の単一 SoT になる(今は失敗が runs.error にしか無く分散)。

所有は **raiser 所有のまま**(raiser が自分の turn で開く。FK cascade は raiser instance に紐づく)。
これは誤った「api root へ所有移管」案(event が raiser を運ばず cascade も壊れる)を**避ける**形。

## 1. base: 全 escalate に row(分類撤廃)

- `reactor.ts` `send` escalate 分岐(:238)の `isUserFacingRequest` gate を撤廃し、**全 escalate で
  `openEscalation` を呼ぶ**。全 escalate が issuer(raiser)を要する(escapeAsk / mcp / external-call
  relay は既に渡している)。
- `escapeAsk`(common.ts:158-177)は既に panic/throw/control/request を `send` 経由で流している
  (gate で row だけ落ちていた)。gate 撤廃で自動的に全部 row になる。**escapeAsk 自体は変更不要**。

## 2. raisePanic/raiseThrow に raiser を通す

`raisePanic`(reactor.ts:279-294)/`raiseThrow`(:300-315)は今 `sendBuffer` に直 push し raiser 無し。
**raiser instance id を引数に足し、`openEscalation` 経路に乗せる**(row を開く)。raiser の出所:
- external-call の `escalateError`/`escalateThrow`(reactor.ts:670 / :650,:658、http-reactor.ts:78):
  raiser = **callee の external-call instance**(`handledInstanceOf(delegation)` / `callByInstance`、存在する)。
- core `onDelegate` の pre-instance panic 2 箇所(core-reactor.ts:175 target 解決失敗、:198 schema 違反の
  防御 panic): callee が生まれていないので raiser = **caller instance**(delegate の発行元)。caller が
  permanent な api run instance の場合は cascade で消えない → §4 の api 明示 retire が拾う。
- これで**全 escalate が raiser 所有の row**になり、base に特例は無い。

## 3. api reactor: dispatch は不変 + 失敗 row は cascade で消える(明示 retire なし)

> **改訂(option C = boundary validation)**: 当初は「api が解決した top failure row を
> `tx.base.deleteEscalation` で明示 retire」する案(option A)だったが、これは *permanent な run instance が
> ephemeral な escalation row の raiser になりうる*(run-start pre-birth 失敗)ことを workaround するもの
> だった。owner の原則: **run instance は run の RESULT CONTAINER として permanent(消すと run の結果 +
> 紐づく resource が cascade で消える)なので、ephemeral row の raiser には絶対にしない**。回避策(明示
> delete)ではなく **境界で防ぐ**(§8)。→ **全 failure row の raiser は mortal になり、run teardown の FK
> cascade で消える。api 明示 retire は不要・削除。**

- `api-reactor.ts` `onEscalate`(:385-417)の dispatch は**不変**: user-facing → answerable(in-memory
  openEscalations、durable row は raiser が既に開いている)/ 失敗・control → run を fail(delegation を
  retire、error outcome、audit、root を terminate)。これは **handler のローカル判定**(許される)。
- **api 明示 retire は無し**。失敗 escalate の raiser は必ず mortal(run subtree 内の core / ffi instance)
  なので、api が root を terminate → subtree teardown が **raiser を drop → その escalation row が cascade**
  で消える(`raiser_instance_id ON DELETE CASCADE`、execution.ts:235-237)。api は ephemeral row を1つも
  所有せず、掃除もしない。冪等: 二重 escalate は `retireDelegation` が false を返す(:402)。
- 失敗 row の raiser が常に mortal であることは §8 の **run-start 境界検証**が保証する(未解決 entry は
  400、transient blip は retryable=503 で launch しない → run delegate が未検証で core に届かない → run
  instance が pre-birth panic の raiser になる経路が消える)。inner delegate(ffi/mcp/webhook)は caller が
  mortal な call instance なので元から問題無し。
- **正しさの要(必ずテスト)**: 失敗が解決される全経路で row が leak しない —
  (i) run を fail する経路: top も中間も **全部 mortal raiser の cascade** で消える(明示 retire なし)。
  (ii) handler が catch する経路(throw が上位の `handle throw` に捕まる): throw は `-> never` で
  非再開なので、catch されると raiser subtree の instance が teardown される → その row 群が cascade。
  (iii) recovery(in-flight 失敗の crash → reactivate): replay で run を fail → teardown → mortal raiser の
  row が cascade。いずれも明示 retire 不要(実測でも catch 後に raiser instance が生き残る経路は無し)。

## 4. read/answerable 面に user-facing filter

今は「to=api なら全部 user-facing」と信じている。失敗も to=api で来るので、answerable 面に
`isUserFacingRequest(request)`(escalation-filter.ts:35-37、純粋 string 述語)を足す — 区別は base でなく
**handler(api)の read** に置く:
- `escalation.repository` listOpen/findOpen(:34-70、`WHERE to_reactor='api'`)に user-facing 条件を追加
  (SQL 条件でも TS post-filter でも可。open escalation は小容量)。
- api `answerableEscalations`(row-store.ts:274 / db-persistence の to=api load)を user-facing に絞る
  → reload した失敗 row を answerable として誤提示しない。
- `run-tree.repository`(:156)の `answerable = to==='api'` を `&& isUserFacingRequest(request)` に。

## 5. 履歴: 失敗も完全ログに

`run_escalations_audit`(execution.ts:369-381、答えた質問のみ)を、**resolved 全部(answered +
failed/cancelled)**を記録する形に。api の fail-run 分岐で audit 行を書く: `question = event.ask.argument`、
`answer = null`(column は nullable、:377 — interface `PersistedRunEscalationAudit.answer` を `Value | null`
に緩める)、`run = event.run`、`escalation = event.escalation`。失敗テキストは既存
`escalationErrorMessage(event)` があるが、audit は question/answer 構造なので answer=null + 別途
run.error に text、で十分(audit は「何が起きたか」の記録)。

## 6. recovery(調査で確認済み、テストで pin)

in-flight 失敗の crash: raiser の失敗 escalate と row が commit 済みで run はまだ running、の窓が
batch 境界で生じうる。reactivate(project-actor.ts:477-511)が全 reactor を reload し **undrained outbox を
replay** → `api.onEscalate` 再駆動 → run を fail(error 記録 + terminate)→ 停止中の raiser instance
(durable、mortal な core / ffi instance)を teardown → その失敗 row が **cascade** で消える(明示 retire
なし)。idempotency guard(retireDelegation false、row-store の idempotent write)で二重駆動しても安全。
§4 の user-facing filter が reload した失敗 row を answerable から除外。テスト: in-flight 外部呼び失敗
(mortal な ffi call instance が raiser)→ reactivate → at-most-once で refuse → panic が bubble → run が
fail + 失敗 row 群が cascade で全部消える(escalationCount 0、ffi envelope 0)。

## 7. 受け入れ基準

- 全 runtime テスト green + 新規(全 escalate が row になる / 失敗 row は cascade で消える(明示 retire
  なし)/ read が user-facing のみ / 失敗も audit / run-start 境界検証 / recovery)。port・compiler・e2e も green。
- **row leak なし**を cancel/catch/fail/recovery の全経路で pin(§3 の要)— 全 raiser が mortal で cascade。
- 挙動: user が答える escalation の見え方・答え方は不変(answerable filter で今と同じ集合)。失敗の
  run-fail 挙動も不変(経路が uniform row になっただけ)。
- base(reactor.ts / external-call-reactor / core relay)から escalation の**種別分類が消える**
  (`isUserFacingRequest`/`isFailureRequest` は api の read と leaf 側にのみ残る)。
- typecheck / lint clean。触った箇所のコメントは why-文へ、分類撤廃の意図を明記。
- adversarial review: (a) 全 emission 経路が row を開く(pre-instance の raiser は常に mortal)、
  (b) answerable 面に失敗が漏れない、(c) 全解決経路で row が cascade され leak しない、
  (d) recovery の in-flight 失敗が replay で正しく fail+cleanup、(e) audit が失敗も記録、
  (f) run-start の transient blip が未検証 launch(wedge)を起こさない、を検証。

## 8. run-start 境界検証(option C — permanent raiser を「作らせない」)

**§3 の cascade-only が成立する前提**: 失敗 escalate の raiser が常に mortal であること。唯一の例外に
なりうるのが **run-start pre-birth 失敗**(run delegate の target が未解決 / arg 不適合 → core の acceptance
surface で panic、callee 未誕生なので raiser 候補は delegate の issuer = **permanent な run instance**)。
これを api で後始末(§旧 option A)するのではなく、**run-start 境界で防ぐ**:

- `project-actor.conformRunArgument`(facade.startRun が launch 前に呼ぶ): entry を resolve + arg を conform。
  - **未解決 entry / arg 不適合(deterministic)** → 拒否メッセージ(facade が **400 BadRequest**)。run は
    起動しない。
  - **transient blip(`TransientError` — DbIrSource.preload の DB read 失敗)** → **defer して launch しては
    いけない**(未検証 run を起動すると、その後 deterministic に失敗した場合 core が run instance を raiser に
    しようとし、`preInstanceRaiser` が undefined→throw、substrate が delegate を drop → run が durably
    `running` のまま **wedge**)。→ TransientError を rethrow、facade が **503 ServiceUnavailable**(retryable)
    にマップ。run は起動しない。
  - **成功** → `null` を返し launch。
- 帰結: **run delegate は必ず検証済みで launch** される → core が run-delegate pre-birth 失敗を見ることは
  無い → `core-reactor.preInstanceRaiser` の undefined-caller throw は「本当に起きたら engine bug」の invariant
  guard(loud throw を **残す**。sub-call は core が caller row を持つので常に mortal で解決)。
- inner delegate(ffi の `context.call`)も対称に **boundary で target resolution + arg を検証**
  (`ffi-reactor.resolveInnerCall`)— 未解決名は catchable な dispatch error(non-callable / bad-arg と同じ扱い、
  callee EXECUTION 失敗の proxy-up とは別)。よって inner delegate も core の pre-instance panic に届かない。
- テスト: (a) run-start で transient IR-load blip → retryable(conformRunArgument が throw)で **run は起動せず**
  wedge しない、(b) 未解決 entry → 拒否(400 相当)、(c) 正常 run は不変で launch。
