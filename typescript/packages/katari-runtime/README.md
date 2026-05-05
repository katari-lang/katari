# katari-runtime

Katari 言語のランタイム実装。

---

## 全体構成

katari-runtime は 2 つのサブシステムで構成される。

### 1. Katari Core Runtime

Katari IR を解釈実行する State Machine。HTTP / 外部からのイベントを受け取り、IR 上の block を Thread として走らせる。

### 2. Sidecar JS Runtime (将来実装)

FFI 機構。`.ktr` ファイルと同名の `.ts` / `.js` に書いた関数を Katari の `ext` 経由で呼び出せる。

`katari-cli` が esbuild で sidecar 群を 1 つの `.mjs` にバンドルし、runtime が初回 ext 呼び出しで `await import(bundlePath)` する想定。本パッケージにはまだ含まれない。

---

## 現状の実装範囲

- IR JSON の型 mirror ([`src/ir/types.ts`](src/ir/types.ts))
- State Machine 本体 ([`src/machine/`](src/machine/))
  - 全 Thread 種別の create / onCall / onChildDone
  - Cancellation 伝播 (cancel / cancelAck / return / done)
  - 5 種類の global exit/cont: `return` / `for_break` / `break` / `for_next` / `next` を boundary thread に直送
  - handle / req / handler 系の dispatch (sequential / parallel)、`next` による resume + state-var 更新、`break` / then-block
  - FFI delegate の往復 (CORE↔FFI)
  - API delegate の往復 (API↔CORE)
  - Lexical scope GC (mark-and-sweep, closure / tuple / array / tagged を trace)
- prim 一通り (算術 / 比較 / 論理 / `tuple_get` / `get_field` / `to_string` / `concat`)。`eq` / `neq` は tuple / array / tagged を構造的に再帰比較、closure は常に `false`。

**未実装**: `statementBindPattern` (let 分解)、API/HTTP レイヤー、永続化 (DB)、sidecar bundling。HTTP API レイヤと DB は別タスクで追加予定。

---

## ディレクトリ構成

```
src/
  index.ts                         公開 API (型と関数を再エクスポート)

  ir/
    types.ts                       Haskell IR の TypeScript mirror

  machine/
    machine.ts                     MachineState 型 + applyEvent
    runner.ts                      processQueue (メインループ) と createThread
    events.ts                      MachineEvent (CORE↔API/FFI 境界イベント)
    id.ts                          ThreadId / ScopeId / DelegationId / EscalationId
    scope.ts                       Scope, MemoryCell 相当の値ストレージ + GC
    value.ts                       Value 型と LiteralValue 変換

    thread/
      types.ts                     RootThreadBase / ChildThreadBase / QueueEvent / Thread
      index.ts                     Thread 種別の再エクスポート
      api.ts                       APIThread (root, API delegation を root として保持)
      user.ts                      UserThread (BlockUser; statement 実行)
      prim.ts                      PrimThread (BlockPrim)
      ctor.ts                      CtorThread (BlockCtor)
      external.ts                  ExternalThread (BlockExternal; FFI delegation)
      match.ts                     MatchThread (BlockMatch)
      for.ts                       ForThread (BlockFor)
      handle.ts                    HandleThread (BlockHandle; ask / next / break / then-block)
      tuple.ts                     TupleThread (BlockTuple)
      array.ts                     ArrayThread (BlockArray)
      request.ts                   RequestThread (BlockRequest; ask 発行 + askComplete 受信)
```

---

## State Machine の設計

### 基本方針

- **同期ループ**: `processQueue` は内部 `QueueEvent` を順次処理し、queue が空になるまで回す。
- **非同期点は外部境界のみ**: API → CORE (`delegate` / `terminate`), FFI → CORE (`delegateAck` / `terminateAck`)。これらは `applyEvent` の inbound として届く。
- **MachineState は in-place mutation**: 関数型分離 (Functional Core / Imperative Shell) は将来検討。今は thread 関数群が `MachineState` を直接書き換える。
- **outbound buffer**: `MachineState.pendingOutEvents` は `applyEvent` 1 回ごとにリセットされる transient 配列。thread 関数群が CORE→API / CORE→FFI の発信イベントをここに push し、`applyEvent` が末尾でまとめて返す。

### 主要な型

#### MachineEvent (CORE 境界)

`{ kind, from, to, ...payload }` の形。`from` / `to` は `"API" | "CORE" | "FFI"` のいずれか。

| kind | from→to | 用途 |
|---|---|---|
| `delegate` | API→CORE | エージェント起動依頼 |
| `delegateAck` | CORE→API | 起動結果返却 |
| `terminate` | API→CORE | エージェント停止依頼 |
| `terminateAck` | CORE→API | 停止完了 |
| `delegate` | CORE→FFI | 外部関数呼び出し |
| `delegateAck` | FFI→CORE | 外部関数結果 |
| `terminate` | CORE→FFI | 外部関数キャンセル |
| `terminateAck` | FFI→CORE | 外部関数キャンセル完了 |
| `escalate` / `escalateAck` | (将来) | request 系拡張 |

#### QueueEvent (内部キュー)

`processQueue` が回す内部イベント。Thread 木の構築・進行・伝播を表す。

| kind | 役割 |
|---|---|
| `callBlock` | top-level callable (top-level agent / prim / ctor / external / request) を子として起動。新 scope の親 = `null` (孤立)。 |
| `callInline` | 構造的 block 内部からの inline 子 dispatch。新 scope の親 = caller の現 scope。 |
| `callValue` | closure 値経由の呼び出し。新 scope の親 = closure の captured scope。 |
| `done` | 子完了通知 (値あり) |
| `return` | 大域脱出 (`return` / `break` / `for_break`) を**境界 thread に直接届ける** (target 指定)。境界が子をキャンセルし `done` に変換 |
| `cancel` | 子の停止要求 (再帰伝播) |
| `cancelAck` | 子からの停止完了通知 |
| `ask` | request 発行: RequestThread → handler-owning HandleThread に直送。`asker` / `askId` が往復で resume 値を結びつける |
| `askComplete` | resume: HandleThread → RequestThread に値を返す。RequestThread は親に `done` を上げる |
| `cont` | `next` / `for_next` を**境界 thread に直接届ける**。modifiers を境界の scope に書き込み、handler body / iter body 1 つだけを cancel して resume / advance |

3 種類の call イベントは「新 scope の親」だけが違う。**全 thread が自分の scope を必ず 1 つ作る**ので、block の種類を見て scope の作り方を変える分岐は runtime に存在しない。

#### Thread

```ts
type Thread = APIThread | UserThread | PrimThread | CtorThread | ExternalThread
            | MatchThread | ForThread | HandleThread | TupleThread | ArrayThread
            | RequestThread;
```

`ThreadBase` は root 用 (`RootThreadBase`, `parent: null`) と child 用 (`ChildThreadBase`, `parent: Thread`) の 2 形に分かれる。`APIThread` のみ root、ほかは child。これにより `parent! / parentCallId!` の non-null assert が消える。

| 種別 | 概要 |
|---|---|
| `APIThread` | 1 delegation = 1 thread。子の done で `delegateAck` を outbound、終了。 |
| `UserThread` | `BlockUser` を実行。`pc` で statement を進める。`statementCall` 時は callTarget の種類で `callBlock` / `callValue` を発行。 |
| `PrimThread` | `BlockPrim`。onCall で計算して即 done。 |
| `CtorThread` | `BlockCtor`。onCall で `tagged` 値を作って即 done。 |
| `ExternalThread` | `BlockExternal`。onCall で `delegate` を FFI に outbound。`delegateAck` 受信で done。 |
| `MatchThread` | `BlockMatch`。subject を評価し pattern bind を thread の scope に書き、armBody を `callInline`。 |
| `ForThread` | `BlockFor`。stateInits を scope に置き、要素ごとに body を `callInline`。`for_break` / `for_next` の境界 (`boundaries.exitKindForBreak` / `contKindForNext`)。`for_next` は `cont` event を受けて modifiers を state vars に書き込み、現 body を targeted cancel → cancelAck で次イテレーションを spawn。 |
| `HandleThread` | `BlockHandle`。`break` / `next` の境界 (`boundaries.exitKindBreak` / `contKindNext`)。`ask` を受けて handler body を spawn (sequential mode は `pendingActions` queue 経由)。`next` で modifiers を state vars に書き、handler body を targeted cancel → cancelAck で `askComplete` を asker に発火。 |
| `TupleThread` / `ArrayThread` | 各要素 block を `callInline`。並列 / 逐次を block 側 flag で切替。 |
| `RequestThread` | `BlockRequest`。**未実装**。 |

### Boundaries (大域脱出の境界)

5 種類の大域脱出 (`return` / `for_break` / `break` / `for_next` / `next`) は、それぞれ対応する境界 thread に直接届けられる。各 thread は `boundaries` field に各 IR kind → 境界 thread の対応を持つ:

```ts
type Boundaries = {
  exitKindReturn: Thread | null;     // 直近の agent UserThread
  exitKindForBreak: Thread | null;   // 直近の ForThread
  exitKindBreak: Thread | null;      // 直近の HandleThread
  contKindForNext: Thread | null;    // 直近の ForThread (cont 用; runtime 未実装)
  contKindNext: Thread | null;       // 直近の HandleThread (cont 用; runtime 未実装)
};
```

- 子 thread は親の `boundaries` を **参照共有** で継承する (どの thread も `boundaries` を直接 mutate しない)。
- 自身が境界となる thread は spread で新オブジェクトを作って該当 key を self に上書きする:
  - UserThread (`blockKindAgent`) → `exitKindReturn`
  - ForThread → `exitKindForBreak` + `contKindForNext`
  - HandleThread → `exitKindBreak` + `contKindNext`
- APIThread は root で agent ではないため `boundaries` の全 key が `null` (= 直下の entry agent UserThread が `exitKindReturn` を自分自身に上書き)。

### Cancellation セマンティクス

`statementExit` (大域脱出) は `boundaries[exitKind]` で境界 thread を引き、その thread を `target` にした `return` キューイベントを発行する。境界 thread は `return` 受信で `cancelling` になり、自身の子に `cancel` を伝播する。各子は次のいずれかで応える:

- `cancelAck` (キャンセルが完了した leaf) — 親が `children.delete` して、`children` が空なら `finishCancelling`
- `done` / `return` — `cancelling` 状態の親はこれらを受けても新規 dispatch せず `checkAllChildrenDone` を呼ぶだけ

`finishCancelling` で:

- `pendingReturn` が立っていれば (= `return` event を受けた境界) `done` を親に出す。`then` ブロックは経由されない。
- 立っていなければ純粋なキャンセル (= 親からのカスケード) なので `cancelAck` を親に出す。
- 自身が root (APIThread) なら `terminateAck` を CORE→API に発信。

親の `return` event の `target` が **既に `cancelling`** だった場合 (親からのキャンセルが先行した race)、`return` は破棄される (値はロスト)。これは「親に取り消されている境界に脱出値を返しても親は受け取らない」ためで、最終的には `cancelAck` が親に出る。

### Handler / Request system

algebraic-effect 型の `req` / `handle` を runtime で dispatch する仕組み。

**handlers field (`Map<ReqId, Thread>`)**: 全 thread が持ち、reqId → handler-owning thread (現状は HandleThread のみ) の対応を保持。boundaries と同様、子は親の handlers を **コピーで継承** する (mutation はしない)。HandleThread が main target を spawn するときだけ、`callInline` event の `handlersOverride` を使って自身の `block.handlers` を載せた augmented map を渡す:

- main target → augmented (parent.handlers + this handle's handlers)
- handler body / thenClause → 継承のみ (this handle's handlers を含めない)

これにより handler body 内から発行された request は **outer の handler が捕まえる** (algebraic effect の標準セマンティクス)。

**ask の流れ**:

1. caller が `request foo()` を実行 → IR の `callTargetBlock` で `BlockRequest` を呼ぶ → RequestThread が caller の子として spawn される。
2. RequestThread.onCall: `handlers.get(reqId)` で handler-owning HandleThread を取得し、`askId` を allocate して `ask` event を発火 (target: HandleThread, asker: self)。
3. HandleThread.onAsk: sequential mode で busy なら `pendingActions` queue に enqueue、idle なら handler body を `callInline` で spawn (callId を allocate)。`childRoles[callId] = { kind: "handlerBody", reqId, askId, asker }` を記録。
4. handler body は handle scope を読み書きしながら走り、最終的に `next v with { ... }` か `break v` を実行する。

**next による resume**:

1. handler body 内 (= HandleThread の子孫) で `statementCont contKindNext` 実行 → `cont` event を境界 (= HandleThread) に直送。modifiers は source thread の scope で **事前評価** され `Map<VarId, Value>` として event に積まれる。
2. HandleThread.onCont: modifiers を自身の scope に書き込む → handler body の callId を source の親チェーンから特定 → `postCancelActions[callId] = { askComplete, asker, askId, value }` を登録 → `cancel` event を handler body に発火。
3. handler body の cancelAck が cleanup を経て届く。HandleThread は `running` のままなので `dispatchOnChildCancelAck` 経由で `onChildCancelAckHandle` が呼ばれる。
4. postCancelAction を実行: `askComplete` event を asker に発火、`busy = false` にして pendingActions から次を pop / dispatch。
5. RequestThread.onAskComplete: 受け取った値で `done` を親 (= 元の caller) に発火し終了。

**break による脱出**: `statementExit exitKindBreak` は boundaries[exitKindBreak] = HandleThread に `return` event を直送。既存の return mechanism がそのまま走り、HandleThread の子全てに cancel をカスケードして finishCancelling で done を親に上げる。

**then-clause**: main target の done が来ると `pendingActions` に thenClause を enqueue (sequential 時)、idle なら即 dispatch。thenClause が done すると、残った子を全 cancel しつつ `pendingReturn = thenResult` で finishCancelling 経路に乗せる。

**parallel mode**: `block.parallel === true` のときは `pendingActions` を bypass、ask 受信で即 spawn。state vars の同時書き込みは event 順 (last-write-wins)。

**FOR_NEXT**: 同じ `cont` event 機構を ForThread が受ける。modifiers を state vars に書き → 現 iteration の body を targeted cancel → cancelAck で `currentIndex++` & 次の body を spawn。

### Closure と scope

- `statementMakeClosure` は `{ kind: "closure", blockId, scopeId: thread.scopeId }` を作る (現スコープを capture)。
- `statementCall callTargetValue` で closure を呼ぶと `callValue` event を発行し、`capturedScopeId` をその event に乗せる。
- `processQueue` が `callValue` を見たら `createScope(machine, capturedScopeId).id` で新 scope を作り、子 thread に持たせる。これにより closure の captured 変数が子から見える。

### FFI 終端契約

- 通常: CORE→FFI `delegate` → FFI→CORE `delegateAck` → 親に done。
- キャンセル: CORE→FFI `terminate` → FFI→CORE `terminateAck` → 親に cancelAck。
- **緩和**: キャンセル中に FFI が `delegateAck` を返してきても、runtime は値を捨て即座に `cancelAck` を親に伝える。これにより「terminate を受けたが既に flight していた delegateAck だけ返って終了」「terminateAck を返さない FFI 実装」でも runtime はハングしない。
- 後から `terminateAck` が届いた場合は `state.delegations` が既に空なので no-op。

### Scope GC

`applyEvent` の末尾で `collectGarbage(state)` が走る。

- ルート: 全生存 thread の `scopeId`
- トレース: scope の親チェーンと、scope 内の値が closure / tuple / array / tagged で持つ `scopeId` を辿る
- スイープ: 到達不能 scope を `state.scopes` から削除

---

## IR 入力の取り扱い

IR は Haskell `Katari.IR.IRModule` を JSON にしたもの。JSON の主要箇所:

- `blocks: Record<BlockId, Block>` — block 集合
- `entries: Record<"module.name", BlockId>` — FFI 境界の名前解決テーブル
  - **キーは `module.name` 形式の文字列** (Haskell 側で `instance ToJSONKey QualifiedName` をカスタム実装してこの形式に固定済み)
  - `module` が空のときはキーは `name` のみ
- `nameTable` — debug 用
- `metadata.schemaVersion` — IR のバージョン

`handleDelegateFromAPI` ([thread/api.ts](src/machine/thread/api.ts)) はこの `entries` を `state.irModule.entries[qualifiedName]` で直接 lookup する。

---

## 検証

```sh
pnpm install
pnpm -r run build      # tsc --noEmit 相当
```

Haskell 側 IR の roundtrip は `stack test katari-compiler` でカバー (`Katari.IRSpec`)。entries の string キー化は同 spec の golden test で固定。

---

## 公開 API

`index.ts` から以下を re-export:

- 関数: `createMachine`, `applyEvent`, `processQueue`, `collectGarbage`
- 型: `MachineState`, `Thread` ファミリー, `Value`, `Scope`, `MachineEvent` 系, `ThreadId` / `ScopeId` / `DelegationId` / `EscalationId`

`MachineEvent` の `args` フィールドは `Record<string, Value>` (JSON 直シリアライズ可能)。内部の `QueueEvent.args` も同形式。

---

## 未決事項

- DB 永続化のタイミング (event ごと / quiescence 後一括)
- sidecar bundle のストレージ (DB blob / FS)
- prim 名の Haskell / TS 同期方法 (共有 const か検出テストか)
- `return` / `break` / `next` を言語レベルで残すかどうか — 構文と合わせて議論中
