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

### イベント

```
ApiInvoke(qualifiedName, args)   # agent 起動
SidecarComplete(threadId, value) # ext call 完了
ApiCancel(sessionId)             # ユーザーキャンセル
```

### 静的概念 (IR から決まる)

| 概念 | 説明 |
|---|---|
| BlockId | IR の callable 識別子 |
| VarId | IR の値スロット識別子 (per-occurrence) |
| ReqId | Request handler 識別子 |
| CtorId | Data constructor 識別子 |

### 動的概念 (実行時に生成)

#### Thread

Block の実体化。以下を保持する。

```
ThreadId → Thread
  blockId     : BlockId
  scopeId     : ScopeId
  parentId    : ThreadId?          # 親 Thread
  handlers    : Map<ReqId, BlockId> # 継承された handler チェーン
  pc          : Int                 # 実行済み statement の個数
  status      : Running
             | WaitingFor(Set<MemoryKey>)
             | Done
             | Cancelled
```

#### Scope

変数の束縛環境。親子チェーンを持つ。

```
ScopeId → Scope
  parentId : ScopeId?
  cells    : Set<MemoryKey>   # この scope に属する cell の一覧
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

`MakeClosure` で生成。Block + Scope の組。

```
ClosureId → Closure
  blockId : BlockId
  scopeId : ScopeId
```

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

### 実行ループ (scheduler)

```
event が来る
  → イベントを適用 (Thread 作成 / MemoryCell fill など)
  → runUntilQuiescence:
       runnable な Thread を全て step
       fill が発生したら待機 Thread を起こして再度 step
       変化がなくなったら終了
  → DB に差分を永続化
```

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
  id         UUID PRIMARY KEY,
  session_id UUID REFERENCES sessions,
  parent_id  UUID REFERENCES threads,
  block_id   TEXT NOT NULL,
  scope_id   UUID REFERENCES scopes,
  pc         INT NOT NULL DEFAULT 0,
  status     TEXT NOT NULL,  -- 'running' | 'waiting' | 'done' | 'cancelled'
  handlers   JSONB NOT NULL DEFAULT '{}'
)

scopes (
  id           UUID PRIMARY KEY,
  parent_id    UUID REFERENCES scopes,
  ir_module_id INT REFERENCES ir_modules
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
  id        UUID PRIMARY KEY,
  block_id  TEXT NOT NULL,
  scope_id  UUID REFERENCES scopes
)
```

---

## 未決事項

- DB の persist タイミング: event ごとに全差分を書くか、quiescence 後にまとめて書くか
- `katari-ffi` パッケージを同 workspace に含めるか
- sidecar bundle のストレージ: DB blob か、ファイルシステムか
- prim 名の Haskell / TS 間の同期方法 (共有 const か、テストで検出か)
