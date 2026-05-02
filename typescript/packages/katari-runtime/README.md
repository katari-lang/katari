# katari-runtime

Katari 言語のランタイム実装。

---

## 全体構成

katari-runtime は 2 つのサブシステムから構成される。

### 1. Katari Core Runtime

Katari IR の実行エンジン。HTTP API でエージェントの起動・状態照会を受け付け、State Machine が IR を解釈して実行する。

### 2. Sidecar JS Runtime

FFI 機構。`.ktr` ファイルと同名の `.ts` / `.js` ファイルに定義した関数を Katari から呼び出せる。

---

## FFI (Sidecar) の方式

**Dynamic import 方式** を採用する。

- `katari-cli` が esbuild を使って sidecar ファイル群を 1 つの `.mjs` に bundle
- runtime が初回 ext call 時に `await import(bundlePath)` で同プロセスに読み込む
- エクスポート形式: `export default { "module.func": fn, ... }` の qualified name マップ

IPC なし。runtime が Node.js である以上、同プロセス import が最もシンプルかつ高速。

### バンドルの責務

```
katari apply
  → Haskell compiler (pure) → IR JSON + ext 参照一覧
  → katari-cli が esbuild API を呼んで bundle.mjs を生成
  → runtime API に POST /apply { irJson, bundleJs } で送付
```

- `katari-compiler` は pure のまま (file IO なし)
- bundler は katari-cli に同梱の esbuild

### katari FFI ライブラリ

sidecar JS 内で `import { call } from "katari"` として使える薄い wrapper。
runtime のベース URL を受け取り、Katari エージェントを呼び出せる。
→ `packages/katari-ffi` として別途実装予定。

---

## Core Runtime のレイヤー構成

```
API Layer        HTTP エンドポイント (Hono)
     ↓
State Machine    同期的な実行エンジン
     ↓
DB Layer         正規化 DB への永続化 (postgres)
```

---

## State Machine の設計

### 基本方針

- **同期的**: State Machine 自体はシングルスレッドの同期ループ
- **非同期点は 2 つのみ**: 外部 API 入力 / Sidecar 完了通知
- **仮想並列**: 実行可能な全 Thread を一斉に step し、quiescence まで回す
- **純粋関数**: State Machine 実行中は DB に触らない。`applyEvent` は純粋な計算として `(MachineState, Event) → (MachineState, DbDiff, Log[])` を返す。DB 書き込みは API 層が差分を受け取って行う (Functional Core / Imperative Shell)。

### イベント

```
Invoke(irModuleId, qualifiedName, args)  # agent 起動 (globalThread を親にして Thread 作成)
FillValue(threadId, value)               # ext call 完了 / 外部入力
CancelThread(threadId)                   # Thread ツリーをキャンセル
LoadIrModule(ir)                         # IR apply (将来は global thread も起動)
```

Session (誰が何を頼んだか) は API 層が管理する。State Machine はイベントを受けて Thread を操作するだけ。

### 静的概念 (IR から決まる)

| 概念 | 説明 |
|---|---|
| IrModuleId | 適用済み IR module の識別子 (apply 時に割り当て) |
| BlockId | IR 内の callable 識別子 (module 内でユニーク) |
| **BlockRef** | `(IrModuleId, BlockId)` — runtime 全体でユニークな block 参照 |
| VarId | IR の値スロット識別子 (per-occurrence) |
| ReqId | Request handler 識別子 |
| CtorId | Data constructor 識別子 |

`BlockId` は IR module 内でしかユニークでないため、Thread・HandlerEntry・Closure が block を参照する場合は常に `BlockRef` を使う。

### 動的概念 (実行時に生成)

#### Thread

Block の実体化。以下を保持する。

```
ThreadId → Thread
  block           : BlockRef   # 実行中の block
  scopeId         : ScopeId    # 字句的 scope (変数参照の起点)
  parentThreadId  : ThreadId?  # 実行ツリー上の親 (動的)
  sessionId       : SessionId  # 所属 session
  handlers        : Map<ReqId, HandlerEntry>
  pc              : Int         # 実行済み statement の個数
  status          : Running
                 | WaitingFor(Set<MemoryKey>)
                 | Done
                 | Cancelled
```

`scopeId` と `parentThreadId` は通常一致するが、**クロージャ呼び出し時は乖離する**。
クロージャ body の Thread の `parentThreadId` は呼び出し元だが、`scopeId` の親は
closure が作られた時点の scope (= `Closure.capturedScopeId` を親とした新 scope)。

#### HandlerEntry

handler は実行時に **登録した `where` block の scope** で動く必要がある (`var s` がその scope に属するため)。

```
HandlerEntry
  block   : BlockRef
  scopeId : ScopeId  # handler を登録した where-block の scope
```

Thread 作成時に親の `handlers` map を引き継ぎ、自身のブロックが持つ handler を上書き merge する。
各 HandlerEntry は登録元の `scopeId` を保持したまま伝播するため、
inner handler が outer handler を shadow しても outer の `scopeId` は失われない。

#### Scope

変数の束縛環境を表す薄い概念。実際の値は MemoryCell が保持する。

```
ScopeId → Scope
  parentId : ScopeId?
```

#### MemoryCell

変数の実態。`(ScopeId, VarId, Version)` で特定。一度 fill されたら immutable。

```
MemoryKey = (ScopeId, VarId, Version)

MemoryCell
  key     : MemoryKey
  status  : Wait | Filled(Value)
  waiters : Set<ThreadId>   # fill 時に起こす Thread
```

#### Closure

`MakeClosure` で生成。Block + 捕捉 Scope の組。

```
ClosureId → Closure
  block           : BlockRef
  capturedScopeId : ScopeId  # closure 作成時点の字句的 scope
```

closure body の Thread を作る際は、`capturedScopeId` を親とした新しい Scope を作成し、
それをその Thread の `scopeId` とする。

### Version の意味

| 文脈 | Version |
|---|---|
| 通常の `let` | 常に 0 |
| `where` block の `var s` | req handler の発火順 (0 = 初期値) |
| `for` block の `var s` | イテレーション index (0 = init, k+1 = k 番目の next) |

`for` は全要素を並列に Thread 化するが、各 version は前の version が fill されないと fill できないため、書き込み順序の整合が保たれる。

### Value 型

```
Value =
  | { kind: "number",  value: number }
  | { kind: "string",  value: string }
  | { kind: "boolean", value: boolean }
  | { kind: "null" }
  | { kind: "tuple",   elements: Value[] }
  | { kind: "tagged",  ctorId: CtorId, fields: Record<string, Value> }
  | { kind: "closure", closureId: ClosureId }
```

### MachineState

```
MachineState
  irModules     : Map<IrModuleId, IRModule>   # read-only (apply 時に追加)
  globalThreads : Map<IrModuleId, ThreadId>   # IR version ごとの global thread (現在は常に空)
  threads       : Map<ThreadId, Thread>
  scopes        : Map<ScopeId, Scope>
  cells         : Map<MemoryKey, MemoryCell>
  closures      : Map<ClosureId, Closure>
```

#### Global Thread (将来の拡張)

Katari のトップレベルに `req` handler / `var` を書けるようにする拡張のフック。
IR version ごとに 1 つの **global thread** を自動起動し、全 agent の Thread はその子として生まれる。
これにより global な `var` 状態・handler が全 agent に自動継承される。

現在は `globalThreads` は空 Map で、`Invoke` は親なし Thread を作る。
将来は `Invoke` が `globalThreads[irModuleId]` を親に指定するだけで拡張が完了する。

global thread 自体は `BlockAgentEntryWithHandlers` 相当で body は空 (handler 登録のみ)。
Done にならず `GlobalWaiting` 状態で待機し続ける (`ThreadStatus` の将来追加 variant)。

### applyEvent (pure)

```
applyEvent(state, event) → { nextState, dbDiff, logs }

  1. event を適用 (Thread 作成 / MemoryCell fill など)
  2. runUntilQuiescence:
       runnable な Thread を全て step
       fill が発生したら waitingFor Thread を起こして再度 step
       変化がなくなったら終了
  3. nextState / dbDiff / logs を返す  ← DB アクセスなし
```

API 層が `dbDiff` を受け取って DB に書き込む。

---

## モジュール構成 (src/)

```
src/
  ir/
    types.ts          Haskell IR の TypeScript mirror
                      (BlockId, VarId, Block, Statement, MatchPattern, ...)

  machine/
    value.ts          Value 型定義
    types.ts          Thread, Scope, MemoryCell, Closure, MachineState 型定義
    memory.ts         MemoryStore: fill / wait / waiter 管理
    scope.ts          ScopeStore: scope 作成・親チェーン参照・var lookup
    thread.ts         Thread 作成・PC advance・状態遷移
    evaluate.ts       Statement 1 個を実行する (MachineState を直接変更)
    scheduler.ts      runnable Thread を全て step → quiescence まで回す
    machine.ts        MachineState + イベントハンドラ (top-level)

  prim/
    index.ts          Map<string, (...args: Value[]) => Value>
                      BlockPrim.name とそのまま一致するキー

  sidecar/
    loader.ts         dynamic import & キャッシュ
    caller.ts         ext call → sidecar 監視 Thread 作成

  db/
    schema.ts         postgres テーブル定義 (マイグレーション SQL)
    queries.ts        CRUD クエリ

  api/
    routes.ts         POST /invoke, POST /apply, GET /status/:id
    server.ts         Hono server セットアップ

  index.ts            エントリポイント
```

---

## DB スキーマ (正規化)

```sql
ir_modules (
  id           SERIAL PRIMARY KEY,
  name         TEXT NOT NULL,
  version_hash TEXT NOT NULL UNIQUE,
  ir_json      JSONB NOT NULL,
  bundle_path  TEXT,
  created_at   TIMESTAMPTZ DEFAULT now()
)

sessions (
  id             UUID PRIMARY KEY,
  ir_module_id   INT REFERENCES ir_modules,
  qualified_name TEXT NOT NULL,
  args_json      JSONB,
  status         TEXT NOT NULL,  -- 'running' | 'done' | 'cancelled'
  result_json    JSONB,
  created_at     TIMESTAMPTZ DEFAULT now(),
  completed_at   TIMESTAMPTZ
)

threads (
  id               UUID PRIMARY KEY,
  session_id       UUID REFERENCES sessions,
  parent_thread_id UUID REFERENCES threads,   -- 実行ツリー上の親 (動的)
  block_id         TEXT NOT NULL,
  scope_id         UUID REFERENCES scopes,    -- 字句的 scope (変数参照の起点)
  pc               INT NOT NULL DEFAULT 0,
  status           TEXT NOT NULL,  -- 'running' | 'waiting' | 'done' | 'cancelled'
  handlers         JSONB NOT NULL DEFAULT '{}'
  -- handlers の要素は { blockId: string, scopeId: string } の map
)

scopes (
  id        UUID PRIMARY KEY,
  parent_id UUID REFERENCES scopes
)

memory_cells (
  scope_id   UUID    NOT NULL REFERENCES scopes,
  var_id     TEXT    NOT NULL,
  version    INT     NOT NULL DEFAULT 0,
  status     TEXT    NOT NULL DEFAULT 'wait',  -- 'wait' | 'filled'
  value_json JSONB,
  PRIMARY KEY (scope_id, var_id, version)
)

closures (
  id                UUID PRIMARY KEY,
  block_id          TEXT NOT NULL,
  captured_scope_id UUID REFERENCES scopes  -- closure 作成時点の字句的 scope
)
```

---

## 未決事項

- DB の persist タイミング: event ごとに全差分を書くか、quiescence 後にまとめて書くか
- `katari-ffi` パッケージを同 workspace に含めるか
- sidecar bundle のストレージ: DB blob か、ファイルシステムか
- prim 名の Haskell / TS 間の同期方法 (共有 const か、テストで検出か)
