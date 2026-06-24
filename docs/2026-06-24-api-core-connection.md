# Katari Runtime — API ↔ CORE 接続 設計 (v0.1.0, scrap-and-build)

> **状態: 設計確定 (2026-06-24)。Step 1–3c 実装済、Step 4 以降 実装中。** main ブランチ(prototype)の
> API/CORE/FFI/ENV module + bus を、**1 actor 内の「instance kind」**に畳んだ軽量版。
>
> 中心となる決定:
> 1. **すべては Instance**(generic interface)。共通 ＋ **`engine_state` だけ kind 別**(`core`/`api`=root)。
> 2. **接続点は 6 対称 external event だけ**(delegate/Ack・escalate/Ack・terminate/Ack)。ユーザー操作も event。
> 3. **永続化は 3 レイヤ + turn = 1 atomic tx**(§6): Layer 1 entity(instances/delegations/escalations、各々
>    独立 SSoT、state machine)/ Layer 2 engine 継続(threads/scopes、entity を FK 参照)/ Layer 3 outbox。
>    entity と継続を分離し、整合は transactional outbox パターンが担保する。

---

## 0. 目的

ユーザー向けの管理面(run の start/cancel/status、user-facing escalation の list/answer)と、IR 実行(CORE
engine)を、**最小の結合点**で繋ぐ。結合点を 6 対称 external event 一本に絞り、それ以外の特別扱い・専用 API を
無くす。

## 1. 原則

1. システムは **instance の木**。親が `delegate` で子 instance を召喚し、`escalate` は上へ、answer は下へ流れる。
2. **接続は 6 対称 external event のみ**。API ↔ CORE の結合はこれ以外に存在しない。
3. **kind は `engine_state` と処理方法だけを変える**。routing(どの instance へ届けるか)は完全に一様で、
   どの instance も — root であっても — 特別扱いしない。

## 2. Instance モデル

```
Instance = {
  id, project_id,
  delegation_id?,            // 自分を召喚した delegation (root は null)
  parent,                    // = delegation の発行元 instance。delegation_id から導出
  status,                    // 'running' | 'cancelling'
  kind,                      // 'core' | 'api'
  delegations,               // 自分が発行した delegate (= parent として)
  escalations,               // 自分が発行した escalate (= child として)
  engine_state,              // ← kind でここだけ違う
  timestamp,
}
```

- `delegations` / `escalations` = **自分が発行した edge**。
  - **delegation の発行は親**(caller が子を召喚)。
  - **escalation の発行は子**(raiser が request を上げる)。
- routing マップ(delegation→child、escalation→raiser、pending の caller)は全部 instance の発行 edge から
  **導出**する(warm では in-memory map、reactivate で再構築)。
- **kind 別なのは `engine_state` のみ**。それ以外は完全に uniform。

## 3. 2つの kind

| | `core` | `api` ( = root ) |
|---|---|---|
| 役割 | IR を走らせる(1 agent activation) | project の管理 top |
| `engine_state` | thread machine(threads / scope refs / routing / counters / 召喚 target+snapshot) | 空(管理状態は共通 fields 側) |
| `delegations` の意味 | sub-agent 呼び出し | **run**(root が走らせた agent) |
| `escalations` の意味 | 自分が上げた request | **user-facing open escalation**(上げ先が無い=open) |
| 処理 | engine turn を駆動 | bookkeeping(§7、audit 書き込み) |
| 寿命 | ephemeral(terminal で self-delete) | permanent(project 毎に1つ。常駐) |

**root を CORE instance にしない**。`engine_state` が空なだけの普通の instance。synthetic thread は無い。
「IR が無いのに thread だけ召喚」という違和感は、**root が `api` kind で thread tree を持たない**ことで消える。
root の特別さは「routing の特別扱い」ではなく「**kind による構造の違い**」に閉じる。

## 4. 接続点 — external event の流れ

ユーザー操作も CORE→ユーザー通知も、すべて同じ 6 event:

```
startRun   : (API入力) root が delegate 発行 → 新しい core instance
run 完了   : core が delegateAck → root が受領 → run を done に
escalation : core が escalate → 親へ bubble → 未処理なら root に届く → root の open escalation に
answer     : (API入力) root が escalateAck 発行 → core を resume
cancel     : (API入力) root が terminate 発行 → core teardown → terminateAck → run を cancelled に
```

→ どの core instance も「top」として特別扱いされない。root は「**上げ先が無い instance**」として一様に escalate を
受け、それが open escalation になるだけ。

## 5. actor(routing + kind dispatch)

main の API module / CORE module / bus を、1 actor 内の kind ハンドラに畳む:

```
actor.feed(externalEvent):                 // ユーザー操作も CORE 由来も同じ口
  target instance へ routing
  dispatch by instance.kind:
     core → driveEngineTurn(instance, event)    // IR(internal queue を quiescence まで)
     api  → handleApi(instance, event)          // bookkeeping + audit/live 書き込み
  turn 境界で 1 tx: { instance state + 発行 edge + outbox + (api なら audit) }
```

`feed` は **serial queue** に積み、その event を処理する turn が終わったら resolve する。
bus の汎用 (from→to) routing は不要 — instance tree の delegation 経由で十分。

## 6. 永続化モデル — 3 レイヤ + turn = 1 atomic tx

**核心原則: 「entity(= 外部 event 語彙、何であるか)」と「engine 継続(= どう再開するか)」を別レイヤにし、FK で
参照、整合は turn 単位の atomic tx が担保する。** instance / delegation / escalation は entity として独立 SSoT を
持ち、thread は継続で entity を FK 参照するだけ。

### Layer 1 — Entities(各々が独立 SSoT、6 external event が駆動する state machine)

```
instances    id, project_id, kind, status, ambient_generics?, timestamps        ← generic な node interface
delegations  id, project_id, issuer_instance_id, target, args, state, timestamps ← call edge
escalations  id, project_id, raiser_instance_id, request, args, state, timestamps← effect edge
```

所有・cascade:
```
instances.delegation_id        → FK delegations  ON DELETE SET NULL  // instance は召喚 delegation に所有されない
delegations.issuer_instance_id → FK instances    ON DELETE CASCADE   // delegation は発行元(親)が所有
escalations.raiser_instance_id → FK instances    ON DELETE CASCADE   // escalation は発行元(子/raiser)が所有
```

- delegation 行は **edge だけ**(thread を知らない)。escalation 行も同様。**entity SSoT**。
- state machine: delegation `running → done / cancelling → gone`、escalation `open → answered / gone`。**state を残して
  履歴も兼ねる(案X)**。close で delete せず終端 state を残す → queryable な履歴。別 audit テーブルは作らない。
- **`runs` は別テーブルではなく projection**: 「`delegations` where `issuer = api root`」が run 一覧。run の result /
  cancel reason 等の user-facing 付加情報だけ `runs` に持つ(= delegation の拡張属性)か、delegation 行に内包。

### Layer 2 — Engine 継続(core instance の実行。Layer 1 を FK 参照)

```
threads / scopes   core の thread tree + scope（owner=instance, cascade）
  DelegateThread        { parent, parentCallId, forwardRoutes, delegationId(FK) }  「D が ack したらこの thread を再開」
  AgentThread.escalations { escalationId(FK) → askId }                             「esc が answer されたら askId を再開」
instances.engine_state  core の counters 等（kind 別 JSONB。api は null）
```

- continuation(parent / askId）は **entity から導出できない別 SSoT**。`delegationId` / `escalationId` は **FK 参照**で
  あって edge の複製ではない。`api` instance は Layer 2 を持たない（thread tree 無し）。

### Layer 3 — Outbox(in-flight な external event = 保留中の遷移)

```
outbox   id, project_id, event(JSONB), created_at   ← 未consume の external event
```

- internal event は instance graph 再実行で再導出できるが、**external event は instance 間の committed handoff で
  再導出できない**。producing turn と**同一 tx**で insert、consuming turn で delete、recovery で未consume を replay
  （transactional outbox）。別 DB にすると atomicity が壊れるので **同一 DB・別テーブル**。

### turn = 1 atomic tx（整合の要）

1 external event を処理する turn は、**1 tx で**次を書く:
```
1 tx = {
  consume した event を outbox から delete
  Layer 1 entity 遷移（delegations/escalations の insert/update、instances.status）
  Layer 2 engine 継続の更新（threads/scopes、core のみ）
  produce した outbound event を outbox に insert
}
```
これで「DelegateThread はあるが delegations 行が無い」窓が**原理的に消える**（前回の懸念の解決）。これは
event-driven 永続化の標準パターン（**transactional outbox + transactional consumer**）。novel なのは Layer 2 を
載せた点だけ。

## 7. Hono service ↔ actor の繋ぎ

**command と query で経路が違う**:

```
command (start/cancel/answer) : HTTP → external event に翻訳 → host.feed → actor
query   (list/get)            : HTTP → repository で audit を直読(actor を通さない)
```

host が API に見せる口は1つ:

```ts
interface RuntimeHost {
  feed(projectId: string, event: ExternalEvent): Promise<void>;  // その event を処理した turn 完了で resolve
}
```

service 層(抜粋):

```ts
// run.service.ts
start(projectId, input):   // runId = newDelegationId(); host.feed(delegate{runId, target, args}); return {runId}
cancel(projectId, runId):  // host.feed(terminate{delegation: runId})
list/get(projectId, …):    // runRepository を直読(audit)

// escalation.service.ts
listOpen(projectId):       // escalationRepository を直読
answer(projectId, escId, value):  // host.feed(escalateAck{escalation: escId, value})
```

→ service 層は「翻訳して feed」か「repo で直読」だけ。run の result も lifecycle promise も持たない
(durable は audit にある)。`feed(delegate)` は「core instance 生成 + runs(running) 書き込み」完了で resolve する
ので、startRun 直後の GET が必ず当たる。

## 8. entity 遷移を書くのは、その event を処理する turn(= §6 の atomic tx)

external event は Layer 1 entity の **state 遷移**。turn が §6 の 1 tx で entity と継続を同時に書く:

```
delegate    : delegations(running) insert + core instance 生成（issuer=発行 instance）
delegateAck : delegations(done, result) update + 発行 instance の DelegateThread を resume
escalate    : escalations(open) insert
escalateAck : escalations(answered) update + raiser を resume
terminate(Ack): delegations(cancelling→gone) + 子の teardown cascade
```

- run / open escalation の **list/get は Layer 1 を直読**（runs = `delegations where issuer = api root`、open escalation =
  `escalations where state = open`）。actor を通さない。
- **`core` ハンドラは Layer 1 の routing 用 entity を直接いじらず**、engine 継続（threads）を動かすだけ。Layer 1 への
  反映は turn 境界の永続化（§6 tx）が、その turn の発行 edge から行う。

## 9. リカバリ（全部 Layer 1/2/3 から一意に再構成）

```
delegations  → delegationCaller(D→issuer)/ delegationChild(D→child)
escalations  → open escalation 一覧 + raiser
instances    → node 群（kind 別に Layer 2 を load）
threads/scopes → core instance の継続（DelegateThread.delegationId / AgentThread.escalations が FK）
outbox       → 未consume を replay
```
turn = 1 atomic tx なので、どこから読んでも整合。`api` root は permanent（id = projectId）。

## 10. 旧設計(現コードベース)からの差分

- run-root を「caller 無しの CORE instance」として特別扱いするのを**廃止** → run は `api` root の delegation、
  実体は普通の `core` instance（親 = root）。【実装済 Step 1–2】
- actor の入口を **`feed(externalEvent)` 中心**に（startRun=delegate / cancel=terminate / answer=escalateAck）。
- `instances` に `kind`、`target`/`snapshot_id` を nullable に。`pendingDelegations` 撤廃（DelegateThread.delegationId が
  SSoT）。【実装済】
- **delegations / escalations を Layer 1 entity（live + 履歴、state を残す）に**。`runs` は delegation の projection。
- **outbox + turn=1 atomic tx** を導入（entity・継続・event を同一 tx で）。

## 11. 実装 Step

```
[済] Step 1  Instance に kind + api root（permanent、id = projectId）
[済] Step 2  event 統一（feed 中心）+ actor kind dispatch
[済] Step 3a instances schema（kind + nullable target/snapshot）+ codec + migration
[済]         pendingDelegations 撤廃（DelegateThread.delegationId が SSoT）
[済] Step 3b 「turn = 1 atomic tx」: Persistence を persistInstance/dropInstance → commitTurn(Layer1+Layer2)。
[済]         EntityTransition で delegation/escalation 遷移を表現、turn の { instance/threads/scopes + entity
[済]         遷移 } を 1 tx で commit（DelegateThread↔delegation 行の atomicity gap を解消）。schema: outbox
[済]         table + delegations/escalations を retained-history state machine 化（migration 0004）。
[済]         DbPersistence は 1 drizzle tx（FK 順: delegation-open→instance→escalation-open/state updates）。
[済] Step 3c reactivate を Layer 1 から: delegations(live)→delegationCaller（run 委譲は thread が無いので table が
[済]         唯一の出所、生存 DelegateThread からも併せて再構築）。検証用 StoringPersistence + recovery test
[済]         （in-flight external 復帰 / run routing を table から復元し結果を done で durable 記録）。
[次] Step 4  runs projection / 付加属性（cancel_reason 等）+ service の list/get を Layer 1 直読に。run 結果は
             promise ではなく delegations(done).result を読む。open escalation も escalations(open) から復元。
[  ] Step 5  outbox を mailbox 供給に統合: api 操作も含め全 external event を outbox に同一 tx 永続化 + 消費を
             dequeue + recovery replay（mailbox = outbox の warm cache に、in-flight event の crash 安全を完成）。
```

> 注: Step 3b で **delegation 行はその子の create turn が書く**（caller は routing から既知、run は api root）。
> これにより startRun/cancelRun は同期のまま（api root 専用 turn を作らずに済む）。caller turn の DelegateThread
> と delegation 行の間の一時的 gap は、recovery が **生存 DelegateThread からも** caller を再構築するため埋まる。
> escalation の answered 反映（api 発の escalateAck）と outbox 永続化は Step 4/5 で完成。
