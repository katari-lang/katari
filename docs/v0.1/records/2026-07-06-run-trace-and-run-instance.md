# 実行トレース (run_events journal) と run instance 化

> 2026-07-06 の設計議論のまとめ。2 つの変更が対になっている:
> (1) run 毎の永続 **run instance** の導入 — run の identity・資源所有・削除単位の再設計
> (2) **実行トレース** — 全 external event を run に帰属させて永続 journal に記録し、CLI / admin-web で表示
>
> `2026-06-24-api-core-connection.md` の「root instance は project に 1 つ」(R4 由来) をここで改訂する。

---

## 1. run instance — run の identity の再設計

### 旧設計の問題

- run の id = 起動 delegation の id だったが、delegation 行は terminal で消える純 live routing。
  **実体より id が長生きする** (`runs.id` だけが残る) という概念的な歪みがあった。
- run 結果が捕捉する資源 (scope / blob) の reown 先が api root (= project 全体) で、run 単位の
  削除・GC ができない (「run 結果 scope GC」が deferred 課題化していた)。
- escalation の run 帰属が「api レベルでは delegation = run」という偶然に依存していた。

### 新設計

**run は永続な api-side instance そのもの**。`ApiReactor` は 2 種類の `api` kind instance を管理する:

| | api root | run instance |
|---|---|---|
| 個数 | project に 1 つ (id = project id) | run 毎に 1 つ |
| 寿命 | project と同じ | **永続** (run の terminal で消えない。将来の run 削除で消える) |
| 所有 | project-scoped 資源 (アップロードファイル) | **run の結果資源** (result が捕捉する scope / blob) |
| envelope | delegation / caller / run 全て null | 同じく null / null / **自分自身の id** |

- `runs.id` = run instance の id。`runs` テーブルは run instance の **class-table 拡張**
  (`core_instances` が core envelope を拡張するのと同型) になり、`runs.id` FK → `instances.id`
  ON DELETE CASCADE。
- run の起動 delegation は fresh な `DelegationId` を持つ純 live edge (caller = run instance)。
  terminal で消える。cancel は `issuedDelegationsOf(runInstance)` から引く。
- run 結果・escalation の質問の reown 先は api root ではなく **run instance** (`event.run`)。
  scope / blob の owner FK → instances CASCADE は既存なので、**将来の run 削除 = instance 1 行の
  DELETE で、runs 行・trace (`run_events`)・結果資源が全部 cascade で消える**。
- envelope の `status` は run instance では常に `running` (実 lifecycle は `runs.state`)。
- run-tree の root 解決は「id = runId の delegation」から「**caller = runId の delegation**」へ。

### 認めたトレードオフ

- `instances` の「行の存在 ⟺ live」不変条件は run instance には当てはまらない (歴史が残る)。
  engine / ffi / http の load は kind で self-select するので実害なし。
- envelope status の意味論は run instance では形骸化 (上表)。

---

## 2. 実行トレース

### イベントへの run 刻印 (trace context)

`ExternalEvent` の封筒は routing (`from` / `to`) に加えて **`run: InstanceId`** を運ぶ。
伝播は 3 規則 (OpenTelemetry の trace context と同型):

1. **起点**: run instance が発行する起動 `delegate` が `run = 自分の id` を刻む (trace の根)。
2. **受理時に記録**: instance は delegate 受理時に `event.run` を ambient (`runId`) として記録
   (`callerReactor` を `from` から記録するのと完全対称)。以後 emit する全イベントに刻む
   (engine 側は `StepContext.emit` の 1 箇所)。envelope 列 `instances.run_id` に永続化、
   reload で復元。base reactor の `handled` index にも run が乗る (`handledRunOf`)。
3. **返信はコピー**: instance を持たない返信 (stray terminateAck、acceptance surface の
   panic / throw) は inbound event の `run` をコピー。

これで全イベントが O(1) で run に帰属する — tree walk 不要、delegation 行が消えた後も有効。

### journal = outbox の恒久版 (ログの SoT)

`Substrate.commit` は turn の全 send を outbox に書く唯一の合流点。**同じ tx** で
`run_events` (seq bigserial, project_id, run_id FK→runs CASCADE, event jsonb, created_at) に追記する。

- **exactly-once**: tx 原子性そのもの。commit 失敗 → 両方 rollback → replay で再 journal。
- **順序**: project actor は serial (turn = 1 commit) なので bigserial = 因果的な production 順。
- **意味**: journal 行 = 「このイベントは durable に送られた」。outbox は配達 (消費で削除)、
  journal は同じストリームの永久記録。
- **at-rest**: outbox と同じく `sealForStorage` (private 値は暗号化)。
- **retention**: runs 行への FK cascade がそのまま保持ポリシー (run 削除 = trace 削除)。

### 読み出し

`GET /projects/:projectId/runs/:runId/events?after=<seq>&limit=<n>` →
`{ state, events: RunEventView[] }`。`state` が同乗するので watcher は 1 poll で
「trace の続き + まだ生きているか」の両方を得る。

`RunEventView` = seq / kind / from / to / delegationId / escalationId / target / ask / request /
**payload** (redact 済み value) / **summary** (server-render の 1 行) / createdAt。
summary は `delegate api→core main.main [4f21ac09]` の形式 — 短縮 id で ack と delegate を目視相関する。

### 表示

- **CLI** `katari run` (watch): wait ループが events を tail し、summary を dim な stderr 行で逐次表示
  (`HH:MM:SS delegate api→core …`)。同じ poll の `state` で終端判定するので、終端 turn の
  イベントも必ず表示してから結果を出す。`katari status <run>` は末尾 20 件の Trace セクションを表示。
- **admin-web** RunDetailPage: Trace カード (kind バッジ + delegate target を後続 leg に相関させた
  行 + payload 展開 + **trace 全体の JSON コピー**)。live 中は 2.5s polling、terminal で停止。

### 決めたこと (仕様の細部)

- 記録対象は external event のみ (internal の call/ask は対象外)。
- panic / throw も escalate として記録される (request 名 `prelude.panic` / `prelude.throw`)。
- escalation の hop-by-hop bubbling は hop 毎に記録される (leaf→親 instance、親→api の 2 対) — 意図的。
- payload の blob 参照は GC 後 dangling になり得る (表示側は参照として出すだけ)。

---

## 3. 触った表 (schema)

- `instances` + `run_id uuid` (FK なし — `caller_reactor` と同じ ambient metadata)
- `escalations` + `run_id uuid NOT NULL` (帰属の明示化; read 側の join も delegation → run_id へ)
- `runs.id` FK → `instances.id` CASCADE (run instance の拡張表化)
- `run_events` 新設 (上述)
- migration は 0000 を作り直し (pre-release につき互換なし)
