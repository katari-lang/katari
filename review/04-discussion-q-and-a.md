# Phase 4: 議論 Q&A — Core 層の抽象化方針

03 のリファクタリング計画に対する質問への応答。

---

## Q1: パッケージ分割の見直し

### 結論

**3 パッケージで十分**:

```
katari-runtime    : engine + facade + snapshot + logger + errors (現 katari-runtime のスコープ)
katari-storage    : Storage interface + 各 backend (現 katari-api-server/storage を切り出し)
katari-api-server : HTTP + wiring + recovery + services + registry (host 層を吸収)
```

または、storage を api-server に同梱して **2 パッケージ** でも良い。

### 03 の "engine / runtime / host" 3 分割は過剰

`katari-compiler` がすべての phase (Lexer / Parser / Typechecker / Lowering / Schema) を 1 パッケージに収めているのと同じく、`katari-runtime` も IR types / engine / facade / snapshot を **同一パッケージ内のサブモジュール** として置けば足りる。

```
katari-runtime/src/
  ir/               IR types (Haskell mirror)
  engine/           pure state machine (= 03 案の "katari-engine")
    machine.ts
    runner.ts
    events.ts
    scope.ts
    value.ts
    pattern.ts
    errors.ts       ← engine 内に閉じる
    logger.ts       ← interface だけ engine に置く
    thread/
  facade.ts         MachineHandle
  snapshot.ts
  index.ts          public API (絞り込む)
```

層境界はディレクトリで担保すれば良い。`engine/` から `facade.ts` を import しないというルールを ESLint や `dependency-cruiser` で強制すれば物理パッケージ分けと同等の保証が得られる。

### engine / runtime / host の概念的な違い (内部層として)

| 層 | 役割 | 依存方向 | "型" |
|---|---|---|---|
| **engine** | Pure state machine。I/O・時刻・乱数なし。`applyEvent` がコア。 | IR のみ | `(State, Event) -> (State, Event[], Error[], Log[], Diff[])` |
| **runtime facade** | engine をラップして "snapshot/restore できる handle" を提供。Logger interface を介して I/O 寄りの adapter 注入を許す。 | engine | `IRModule, Snapshot? -> MachineHandle` <br>`MachineHandle.feedEvent(Event) -> Event[]` |
| **host** | 永続化・並行制御・FFI dispatch・cron/scheduler 等の **process 内 I/O** を engine の前後に貼り付ける。 | runtime, storage | `Storage × Registry × FFIExecutor -> AgentService` |

この区別は **概念的に存在するが、物理パッケージとして分ける必要はない**。`katari-api-server/src/` の中で `services/` `registry.ts` `ffi/` 等のサブディレクトリで表現して構わない。

03 で `katari-host` と書いたのは「将来 CLI runner / embedded runner 等の host を別形態で作る可能性」を念頭に置いたが、現時点ではそういう要求が無いので **不要**。実際に必要になったら、`katari-api-server/src/host/` を抽出すれば良い。

---

## Q2: Core の抽象化方針

### 2.1 (Event, State) => Result の関数型モデルへ

提案された signature:

```ts
type Result = {
  state: State;          // 新しい State (immutable)
  outbound: Event[];     // 外向き event
  errors: EngineError[]; // この event で発生した error 群
  logs: LogEntry[];      // log 出力
  diffs: Diff[];         // State の差分
};

function applyEvent(state: State, event: Event): Result
```

**State は immutable な data structure** にする。現行は `MachineState` を in-place mutation しているため:
- snapshot 取得時にコピーが必要
- diff 抽出のために state を 2 回保持して比較する手間
- thread 関数群が `MachineState` を引数で受けるが暗黙の mutation で副作用が走る

これを廃して、threads / scopes / queue 等を **immutable** または **構造的共有 (Immer)** に置き換える:

```ts
type State = {
  irModule: IRModule;
  threads: ImmMap<ThreadId, ThreadData>;
  scopes:  ImmMap<ScopeId, ScopeData>;
  routing: ImmMap<DelegationId, ThreadId>;  // 後述: APIThread の脱特別扱い
  queue:   List<QueueEvent>;
  // logger / pendingOutEvents / lastGcScopeCount は state に持たない (Result に分離)
};
```

実装には [Immer](https://immerjs.github.io/immer/) を使うか、自前で COW (copy-on-write) する。Immer なら `produce(state, draft => ...)` と書ける + patches が auto-derive されるので diff machinery とも相性が良い。

### 2.2 Event の from/to 完全抽象化

旧 `katari-protocol` のように、Endpoint を完全に抽象化:

```ts
type Endpoint =
  | { kind: "core" }
  | { kind: "external"; id: ExternalEndpointId };
// ↑ "API" / "FFI" / "DB" / 将来の peer core などを id で区別
```

`MachineEvent` は:

```ts
type MachineEvent = {
  from: Endpoint;
  to: Endpoint;
  payload: EventPayload;
};
```

`EventPayload` は現状の `delegate / delegateAck / terminate / terminateAck / escalate / escalateAck` 系。`from`/`to` の対応で routing は外側 (host) が担う。

**Core → Core event** は `from.kind === "core" && to.kind === "core"` で表現できる (将来の multi-core 連携を見据えた拡張余地)。

### 2.3 Diff 抽象化

```ts
type Diff =
  | { op: "thread.create"; threadId; data }
  | { op: "thread.update"; threadId; patch }
  | { op: "thread.delete"; threadId }
  | { op: "scope.create"; scopeId; data }
  | { op: "scope.set";    scopeId; varId; value }
  | { op: "scope.delete"; scopeId }
  | { op: "routing.set";  delegationId; threadId }
  | { op: "routing.delete"; delegationId };
```

これで `Storage.applyDiffs(diffs)` が書ける → snapshot 一括書き換えではなく **incremental persist** が可能。Immer の `produceWithPatches` を使えば diff 生成も自動化できる (Immer patches を上記 Diff 型に翻訳)。

### 2.4 Thread 最小 interface

提案された 6 method を採用:

```ts
type ThreadMethods = {
  create(init: Init, state: State): Result;
  done(callId: CallId, value: Value, state: State): Result;
  cancel(state: State): Result;
  cancelAck(callId: CallId, state: State): Result;
  ask(askId: AskId, kind: AskKind, payload: Value, state: State): Result;
  askAck(askId: AskId, value: Value, state: State): Result;
};
```

各 thread variant は上記 6 method をすべて実装。実装が無い method (例: prim thread の `ask`) は **trivial proxy** または **invariant violation error** を出す。

`runner.ts` は **block kind による factory での出し分け以外、一切の switch を持たない** (現状の哲学そのまま)。

### 2.5 ask の bubbling 設計

提案された方式:

> ask は親に投げるだけ (現在の仕組みのように間を吹き飛ばさない)。

これにより `boundaries` map が **不要** になる。各 thread は ask を受けたら:
- **自分が catch する種類**なら自前のロジックで処理 → askAck を子に返す。
- **catch しない**なら親に proxy。

特殊 ask の対応表:

| Ask kind | catch する thread variant |
|---|---|
| `request(reqId, args)` | HandleThread (該当 reqId の handler を持つ最も近い祖先) |
| `return v`             | UserThread (block.kind = agent) |
| `break v`              | HandleThread |
| `next v with mods`     | HandleThread |
| `break-for v`          | ForThread |
| `next-for v with mods` | ForThread |

それ以外の thread (例: TupleThread) は ask を **そのまま親に proxy** する。

#### bubbling の semantics

```
[child]                       [intermediate]              [boundary]
   │                               │                          │
   │── ask(askId=A, kind=K) ──────▶│                          │
   │                               │── ask(askId=A, kind=K) ─▶│
   │                               │                          │ catch
   │                               │                          │ ... (cancel下流, cancelAck待ち)
   │                               │◀── askAck(askId=A, v) ───│
   │◀── askAck(askId=A, v) ────────│                          │
```

`askId` は asker が allocate して、bubble した先の boundary が同じ askId で askAck を返す。中間 thread は **askId を改変せず proxy** する。

#### `next` の specifics

handler thread が `ask: next, payload, mods` を受けたとき:

1. mods を自分の scope に書き込む。
2. ask の発信元 child (= 自分の直接の子で、ask source の祖先) を特定 (現状の `findImmediateChildCallId`)。
3. その child に `cancel` を送る。
4. cancelAck を受けたら、`askAck(askId, payload)` を **元の asker** に返す (要: asker の thread id を保持)。

但し、bubble 経由だと asker の thread id を直接知らない。askId だけが asker と handler を紐付ける。
→ handler は ask を受けた時点で `(askId → 直接子 callId)` の map を作る。askAck を返すときは「直接子に送る」。直接子はさらに proxy で下流へ送る (ask が来た方向の逆)。

つまり **proxy thread は (askId → 子 callId) の map を持って、askAck を該当子に降ろす** 必要がある。これが bubble モデルの追加コスト。

#### `break` / `return` の specifics

これらは値を運んで boundary に到達 → boundary が全子 cancel → cancelAck 待ち → 上流に done。
askAck で返すのではなく **done event に変換** されるので、askId の対応は不要。

→ 整理: ask kind ごとに「askAck で返すか」「done で返すか」の policy が異なる:

| ask kind | 終端 |
|---|---|
| `request` | askAck (asker = RequestThread が done に変換) |
| `next` | askAck (asker = RequestThread が done に変換) |
| `next-for` | askAck (asker は誰?) |
| `return` | done を上流に (askAck は不要) |
| `break` | done を上流に |
| `break-for` | done を上流に |

`return / break / break-for` は値を「自分の親に done として伝える」アクションなので、ask 抽象に乗せる必然性がやや弱い。**素直に boundary に done を逆向きに伝える機構を残す**方が綺麗かもしれない。

提案: **2 種類の bubbling op を区別する**:
- `request` 型 ask: askId 必要、askAck で答える、bubbling proxy が askId map を維持。
- `exit` 型 ask: askId 不要、boundary に到達した時点で done に変換、proxy はない (その thread が catch するかしないかだけ判定)。

実装は近いがセマンティクスが違うので別 method として切り分けるとさらに綺麗:

```ts
type ThreadMethods = {
  create(init): Result;
  done(callId, value): Result;
  cancel(): Result;
  cancelAck(callId): Result;
  ask(askId, kind, payload): Result;       // request 型
  askAck(askId, value): Result;             // request 型
  exit(kind, value, mods?): Result;         // return / break / break-for
  cont(kind, value, mods): Result;          // next / next-for ← request 型に近いが done で終わらない
};
```

まあ exit と cont は ask の特殊形と見做して:

```ts
ask(askId, kind: "request" | "next" | "next-for", payload, mods?): Result;
exit(kind: "return" | "break" | "break-for", value): Result;
```

くらいの分け方が現実的。

### 2.6 APIThread の脱特別扱い

提案通り、**APIThread を消し、外部 event は普通の create event に翻訳する**。

```ts
// host 側
class DelegationRouter {
  private routing = new Map<DelegationId, ThreadId>();

  onExternalDelegate(event: { from: External, to: Core, kind: "delegate", qualifiedName, args, delegationId }, machine: Machine): void {
    const blockId = machine.irModule.entries[qualifiedName];
    const threadId = createThreadId();
    this.routing.set(event.delegationId, threadId);
    machine.feedEvent({
      from: { kind: "core" },
      to: { kind: "core" },
      kind: "create",
      threadId,
      blockId,
      args: event.args,
      parent: null,  // root thread
    });
  }

  onMachineOutbound(events: MachineEvent[]): ExternalEvent[] {
    const result = [];
    for (const e of events) {
      if (e.kind === "rootDone") {
        const delegationId = this.lookupByThreadId(e.threadId);
        result.push({ from: Core, to: External, kind: "delegateAck", delegationId, value: e.value });
        this.routing.delete(delegationId);
      }
      // ... terminate / terminateAck も同様
    }
    return result;
  }
}
```

**Engine 側は DelegationId を一切知らない**。Engine は「parent=null の thread が done した」というイベントを発信するだけ。Routing は host 層の責務。

これで:
- engine の thread 階層に root も leaf も同じ抽象として収まる。
- `state.delegations` / `state.apiDelegations` が engine から消える (host に移る)。
- `applyEvent` の case 文に `delegate API→CORE` の特別扱いが消える (= "create thread with parent=null" event)。

### 2.7 Bubbling モデルの tradeoffs

| 項目 | 現行 (boundary 直送) | 提案 (bubbling) |
|---|---|---|
| 遅延 (event 数) | O(1) | O(depth) |
| 抽象度 | thread が boundary map を持つ (型 narrow も必要) | 全 thread が parent しか知らない |
| 実装複雑度 | 各 thread が自分の boundary 種別を知る | proxy thread が askId map を持つ |
| race | boundary に直接届く ⇒ race 単純 | 中間 thread の cancel と ask forward が race |

**思想的には bubbling が圧勝**。abstraction の純度が高い。性能上の懸念は通常の Katari プログラムでは tree depth が高々十数なので問題にならない。

### 2.8 残課題

1. **bubbling 中の cancel race**: ask が thread A → B → C → H と bubble している途中で、B が H から cancel カスケードを受けるケース。B が "cancelling" 中なら ask を破棄するのか proxy 続行するのか? 提案: cancelling thread は **後から来た ask を破棄** + 親に proxy しない。askId は host 側のタイムアウトで recovery (但し普通こうしたケースでは asker も同じ cancel 系列下にいるので、askAck を返さなくても asker も cancelAck で消える)。

2. **modifiers の評価タイミング**: 現状は source thread の scope で先評価して `Map<VarId, Value>` を event に積む。bubbling モデルでも同じで OK。ただし proxy thread が中継するので、event payload に既評価の値を載せるのは引き続き必要。

3. **handler が break 中に next が race**: handler thread が break で全子 cancel → 中の handler body が `next` を ask として上方に送ろうとする。break が先に処理されているなら status="cancelling" で next ask は破棄。OK。

4. **GC のタイミング**: 関数型モデルなら state 渡し時に reachable 計算を毎回やるのは高い。**diffs から増減を追跡する incremental GC** にするか、**従来の mark-and-sweep を非同期で走らせる** 形にする。

---

## Q3: Module ごとの "型"

### 3.1 IR layer

```haskell
-- 型のみ。関数なし。
data IRModule, Block, Statement, Pattern, ...
```

### 3.2 Engine

```ts
// 純粋関数群。
type State = {
  irModule: IRModule;
  threads: ImmMap<ThreadId, ThreadData>;
  scopes:  ImmMap<ScopeId, ScopeData>;
  queue:   List<QueueEvent>;
};

type Result = {
  state: State;
  outbound: MachineEvent[];
  errors: EngineError[];
  logs: LogEntry[];
  diffs: Diff[];
};

createMachine: (irModule: IRModule) => State

applyEvent: (state: State, event: MachineEvent) => Result
// 内部でprocessQueue相当 (queue が空になるまで内部 step を回す)
// 副作用なし。state は新しいインスタンス。

step: (state: State) => Result
// 1 つの内部 event を処理して新 state を返す (テスト用低レベル API)

collectGarbage: (state: State) => { state: State; diffs: Diff[] }

// Thread methods: thread variant ごとに pure function
// ThreadOps[K] = (variantData, args) => Result
// 各 method の signature:
//   create:     (state, threadId, init) => Result
//   done:       (state, threadId, callId, value) => Result
//   cancel:     (state, threadId) => Result
//   cancelAck:  (state, threadId, callId) => Result
//   ask:        (state, threadId, askId, kind, payload, mods?) => Result
//   askAck:     (state, threadId, askId, value) => Result
```

### 3.3 Snapshot

```ts
type Snapshot = { schemaVersion: number; ... };

serialize:   (state: State) => Snapshot
deserialize: (irModule: IRModule, snapshot: Snapshot) => State
```

### 3.4 Diff

```ts
type Diff = ...  // 上記 2.3 参照

computeDiff: (before: State, after: State) => Diff[]
applyDiff:   (state: State, diffs: Diff[]) => State
```

または engine の `Result` から diffs を直接受け取る (Immer patches → Diff[] 翻訳)。

### 3.5 MachineHandle (facade)

```ts
class MachineHandle {
  static create(irModule, logger): MachineHandle;
  static fromSnapshot(irModule, snapshot, logger): MachineHandle;

  feedEvent(event: MachineEvent): {
    outbound: MachineEvent[];
    errors: EngineError[];
    diffs: Diff[];
  };

  toSnapshot(): Snapshot;
  // logger / 内部 state は隠蔽
}
```

### 3.6 Storage

```ts
interface Storage {
  modules: ModuleRepo;     // CRUD on IRModule + SchemaBundle
  agents: AgentRepo;       // CRUD on AgentRow (state lifecycle)
  snapshots: SnapshotRepo; // get/upsert/delete Snapshot per versionId
  diffs?: DiffRepo;        // (optional) append-only Diff log per versionId
  withTransaction<T>(fn: (tx: Storage) => Promise<T>): Promise<T>;
  close?(): Promise<void>;
}
```

### 3.7 DelegationRouter (host 層)

```ts
class DelegationRouter {
  // 外部→内部
  translateInbound(external: ExternalEvent): MachineEvent[];
  // 内部→外部
  translateOutbound(internal: MachineEvent[]): ExternalEvent[];
  // delegationId ↔ threadId の bookkeeping
}
```

### 3.8 FFIExecutor (host 層)

```ts
interface FFIExecutor {
  invoke(name: QualifiedName, args, delegationId, timeoutMs): Promise<void>;
  // 結果は MachineHandle.feedEvent({ kind: "delegateAck", from: FFI, to: CORE, ... }) に流す
  cancel(delegationId): Promise<void>;
}
```

### 3.9 MachineRegistry

```ts
class MachineRegistry {
  acquire(versionId): Promise<MachineHandle>;
  evict(versionId): void;
  getMutex(versionId): Mutex;
}

class MachineRebuilder {
  rebuild(versionId, snapshot): Promise<MachineHandle>;
}
```

### 3.10 AgentService (api-server)

```ts
class AgentService {
  startAgent(input): Promise<{ agentId }>;
  cancelAgent(agentId): Promise<AgentRow>;
  resumeCancellingOnBoot(agentId): Promise<void>;
  getAgent(agentId): Promise<AgentRow>;
  listAgents(filter): Promise<AgentRow[]>;
}

class OutboundEventDispatcher {
  route(events: MachineEvent[], versionId, tx): Promise<void>;
  // delegateAck → agent.setState(succeeded)
  // terminateAck → agent.setState(cancelled)
  // CORE→FFI → FFIExecutor.invoke
}

class PoisonHandler {
  poison(versionId, triggeringAgentId, err): Promise<void>;
}
```

### 3.11 Routes

```
POST /module                   : (IRModule, SchemaBundle) -> { versionId }
GET  /module                   : ?(limit, offset) -> ModuleSummary[]
GET  /module/:versionId        : versionId -> ModuleMetadata
GET  /module/:versionId/ir     : versionId -> IRModule  (新規)
DELETE /module/:versionId      : versionId -> 204       (新規)

POST /agent                    : (versionId, qualifiedName, args) -> { agentId }
GET  /agent                    : ?(versionId, limit, offset) -> AgentRow[]
GET  /agent/:agentId           : agentId -> AgentRow
POST /agent/:agentId/cancel    : agentId -> AgentRow

GET  /agent-definition?versionId=...           : versionId -> AgentDefinition[]
GET  /agent-definition/:versionId/:qName       : (v, q) -> AgentDefinition
```

---

## まとめ

質問への直接の答え:

1. **パッケージ分割**: 過剰だった。`katari-runtime` + `katari-storage` + `katari-api-server` の 3 つで十分。`engine` は内部サブモジュール、`host` は api-server に吸収。

2. **Core 抽象化**: 全面同意。
   - `(State, Event) => (State, Event[], Error[], Log[], Diff[])` の関数型モデルへ
   - State は immutable (Immer or 自前 COW)
   - Endpoint は完全抽象化 (旧 katari-protocol スタイル)
   - Diff は Immer patches を Domain 用 Diff 型に翻訳して持つ
   - Thread は 6 method (`create / done / cancel / cancelAck / ask / askAck`) のみ
   - `return / break` 系は ask の特殊形 (もしくは独立 method `exit/cont`)
   - bubbling: ask は親にしか投げない。中間 thread は proxy + askId map
   - **APIThread は廃止**。host 層の DelegationRouter が外部 event ↔ 内部 create event の翻訳を担う

3. **Module の型**: 上記 3.1〜3.11 を参照。

### 残検討

- **bubbling の cancel × ask race**: cancelling thread が ask を破棄する semantics の確定
- **next ask の終端**: askAck で返すか done に変換するか (handler thread が cancel-ack 待ち後にどちらを発信するか)
- **incremental GC**: diff から reach 増減を追跡する設計
- **Immer 採用 vs 自前 immutable**: 性能と可読性の比較
- **modifiers の事前評価**: 現状通り source の scope で評価してから event に積む方針を維持
