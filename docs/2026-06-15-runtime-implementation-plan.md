# Katari Runtime — 実装計画 (v0.1.0, scrap-and-build)

> [runtime-domain-model](2026-06-15-runtime-domain-model.md) を実装に落とす計画。
> 現状 `typescript/runtime/` は hono scaffold (users/health は placeholder) のみ。
>
> **方法論: IO 表面先行 (interface-first)。** 各概念の表面 layer (HTTP の zod schema・
> service interface・repository signature・engine façade と型) を先に stub で固め、
> 全 input/output を型で確定 (`pnpm typecheck` green) してから中身を埋める。compiler の
> phase pipeline scaffold ([[project_compiler_phase_pipeline]]) と同じやり方。

---

## 0. 完了済み

- **IR** (`Katari.Data.IR`): 確定。runtime はこれを読む (変更しない)。
- **hono scaffold**: `createApp()` factory・middleware・`/api/v1`・zValidator・drizzle
  client・layered module パターン (users/health = 参考用 placeholder、撤去予定)。

## 1. 全体レイアウト

```
typescript/runtime/src/
  modules/<resource>/        ← stateless HTTP リソース (scaffold パターン踏襲)
    <r>.routes.ts  <r>.service.ts  <r>.repository.ts  <r>.table.ts  <r>.schema.ts
    リソース: project / snapshot / run / escalation / file / env / agent
  runtime/
    actor/                   ← ProjectActor (serial loop, warm Map, reactivation)
    engine/                  ← 1 instance = thread ツリー。内部イベント・scope・closure・GC
      thread/ops/            ← IR operation ごとの実装 (main の engine/thread/ops を体系化移植)
    instance/                ← instance lifecycle・ownership・cascade・ascent
    value/                   ← Value 型・blob store・codec・inline↔ref 昇格
    event/                   ← internal (6) + external (6) event 型と dispatch
    external/                ← FFI external thread (sidecar 連携)・ENV prim
    persistence/             ← engine graph の load/persist (per-quantum)・recovery
    facade.ts                ← feed / startRun / cancel / answerEscalation (service の入口)
  db/
    schema.ts                ← 全 table 集約 (drizzle)
```

---

## 2. Phase 1 — IO 表面 / scaffold (全 stub, typecheck green)

> ゴール: **全概念の input/output が型で確定し、`pnpm typecheck` が通る**。中身は全部
> `throw new Error("not implemented")` か placeholder。ここで API・engine・persistence の
> 境界を握り、以降の Phase は「中身を埋めるだけ」にする。

### 1a. DB schema (永続の IO 表面)
- domain-model §6 の全 table を drizzle で定義 (`*.table.ts` + `db/schema.ts` に集約)。
- migration 生成 (drizzle-kit)。users/health placeholder を撤去。

### 1b. Value / event の型 (engine の IO 表面)
- `value/types.ts`: `Value` (scalar / record / array / closure / ref(blob)) を型定義。
- `event/types.ts`: 外部 6 (delegate/…) + 内部 6 (call/callAck/ask/askAck/cancel/cancelAck)
  を kind-tagged union で定義。`Event = { from, to, payload }`。
- `engine/types.ts`: `Instance` / `Thread`(kind 別 variant) / `Scope` / `Closure` の型。
  IRModule は compiler 側型を import。

### 1c. engine façade + repository signature
- `facade.ts`: `feed(event): Promise<...>`, `startRun`, `cancel`, `answerEscalation` の
  **signature のみ** (stub)。
- `persistence/`: `loadInstanceGraph(id)` / `persistDirty(...)` / `recover()` の signature。
- `value/blob-store.ts`: `put / get / getRange / delete` の interface (FS 実装は Phase 2)。

### 1d. HTTP リソース (frontend の IO 表面)
各 `modules/<resource>/` を scaffold パターンで stub:
- `*.schema.ts`: zod で input/output を**完全に specify** (これが API 契約)。
- `*.routes.ts`: zValidator + thin handler、service を呼ぶ。
- `*.service.ts`: signature のみ (engine façade / repository を呼ぶ形だけ書く)。
- `*.repository.ts`: drizzle query の signature のみ。
- 対象: project / snapshot / run / escalation / file / env / agent。

→ この時点で `pnpm typecheck` green、API の OpenAPI/RPC 型が確定、engine の全境界が型で
固定される。**ここまでを最初のマイルストーンにする。**

---

## 3. Phase 2+ — 中身を埋める (内部, bottom-up)

> 各 Phase の終わりに対応する e2e/unit を足し、typecheck + test green を保つ。

### Phase 2 — Value 層
- Value codec (JSON 化 / 復元)、scalar 比較、blob store (FS 実装)。
- inline → blob 昇格 (閾値超 string)。`hash` 計算。参照値 (ref) の解決 (bounded fetch)。

### Phase 3 — engine core (intra-instance, 内部イベント)
- scope / variable: 作成・親鎖 walk・束縛。
- thread ops: IR operation を 1 つずつ (`OperationLoadLiteral` / `MakeRecord` / `MakeTuple`
  / `GetField` / `BindPattern` / `Call`(構造ノードを in-shard spawn) / `Exit` / `Continue`
  / `MakeClosure` / `ApplyGenerics`)。`Delegate` は Phase 4 (常に子 instance 召喚)。main の
  `engine/thread/ops/*` を体系化移植。
- 構造ノード: `BlockMatch` / `BlockFor` / `BlockHandle` / `BlockParallel`。
- 内部イベント dispatch: call/callAck・ask/askAck (return/break/next/request の上昇)・
  cancel/cancelAck。pattern match (`engine/pattern`)。
- **Immer は使わない** (drop 済み [[project_immer_drop]])。型付き walker で graph を扱う
  ([[project_checkpoint_typed_walker]])。

### Phase 4 — instance lifecycle (inter-instance, 外部イベント)
- `OperationDelegate` → 常に子 instance 召喚 (named=`(qname,snapshot)` / closure 参照、
  区別なく delegate) / delegateAck で結果回収。closure delegate は新 instance の body scope
  を captured scope (CORE-global store) に親リンク。
- escalate / escalateAck (in-CORE handle で捕まらない分が上昇)。
- terminate / terminateAck (cancel cascade)。
- ownership: scope/closure/blob の owner 付与。cascade delete。
- **ascent**: detach (脱出集合 owner=NULL) → 親が claim。reachability drag (capture 辺)。
- **intra-instance GC**: owned scope のみ mark-sweep (親所有は root 扱い)。

### Phase 5 — external (FFI / ENV)
- FFI: `BlockExternal` thread が sidecar へ dispatch → **suspend (quantum 切り) → 応答で
  resume**。`external_calls` に in-flight 記録 (crash recovery)。sidecar manager (subprocess)。
- ENV: `get_env` / `set_env` を engine 内 primitive として inline 実行 (`env_entries`)。

### Phase 6 — persistence / recovery
- engine graph の load/persist (per-quantum, dirty tracking)。domain-model §6 の粒度判断を
  ここで確定 (行ごと 3NF を試し、重ければ instance 単位 JSONB に退避)。
- crash recovery: 最後の checkpoint reload + in-flight (suspended external / delegation) の
  re-drive。

### Phase 7 — ProjectActor (host)
- `Map<projectId, ProjectActor>` を module scope に warm 保持。serial event loop
  (per-project)。最初の event で lazy reactivate。quantum = load → 実行 (bounded fetch
  inline await) → persist。

### Phase 8 — HTTP service ↔ engine 配線
- Phase 1 で stub にした各 service を engine façade / repository に接続。
  startRun → root instance からの delegate、cancel → terminate、answerEscalation →
  escalateAck、file upload → blob produce + root instance 所有、snapshot deploy → IR 格納。

### Phase 9 — e2e / sample
- compiler (IR) → runtime のフルパス e2e ([[feedback_e2e_layout]] の `e2e/` package)。
- 既存 sample を新 runtime で回す。compiler 変更があれば katari binary 再ビルド
  ([[feedback_rebuild_katari_binary]])。

---

## 4. 進め方の原則

- **Phase 1 (IO 表面) を最優先で完成**させ、そこで一度立ち止まって API 契約と engine 境界を
  レビューする。以降は境界を固定したまま中身を埋める。
- main の `engine/` は実装の宝庫 (runner/spawn/thread/ops/pattern/gc が動く) なので、
  **ロジックは大いに流用**しつつ、module/bus 撤廃・単一 CORE・blob 2 軸・型付き walker の
  現状に合わせて再構成する (コピーではなく体系化移植)。
- 各概念の I/O を先に specify する方針上、**型 (zod schema + TS 型) が仕様書**になる。
  doc とコードが乖離したら型を SSoT とする。
```
