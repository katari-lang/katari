# Phase 2: 各モジュールの詳細評価

Phase 1 で同定した責務分担を前提に、潜在バグ・実装漏れ・責務違反を箇条書きで列挙する。深刻度は **[B] Bug (動作不正)**, **[L] Leak (リソース)**, **[D] Design (設計)**, **[I] Incomplete (実装漏れ)**, **[S] Smell (コード品質)** で分類。

## A. katari-runtime — 核 state machine

### A.1 [machine/machine.ts](../typescript/packages/katari-runtime/src/machine/machine.ts)

- **[D]** `MachineState.logger` を持つことで machine/ → runtime/ の循環依存。`Logger` interface を `machine/` に置くか、event 発火時に caller から渡す形に変更すべき。
- **[D]** `pendingOutEvents` が「transient bufferだが state に置く」設計。Thread コードがどこから書いても reachable な mutable state を抱えるため、テスト容易性とリーズニング困難性のトレードオフ。`applyEvent` 内のローカル変数 + 関数引数で渡す方が原則 (但し thread が深い再帰になるため現状のは実装容易性優先と理解)。
- **[D]** `applyEvent` の case `escalate` / `escalateAck` がノーオプ + log。"future feature" として残すのは良いが、引数 (escalationId 等) の型シェイプが既に events.ts にある。中途半端。
- **[B?]** `applyEvent` が throw した場合、`state.pendingOutEvents` が部分書き込みのまま残る。次の applyEvent が来た時に冒頭で `state.pendingOutEvents = []` で reset されるので "メモリ上は" 漏れない。但し caller (api-server) はこの throw 後に handle を **再作成しない** と stale state が残る (実際 versionedRollback で再作成している)。

### A.2 [machine/runner.ts](../typescript/packages/katari-runtime/src/machine/runner.ts)

- **[S]** `createThreadFromBlock` の switch だけが残っており、これは IR factory として正当。OK。
- **[B]** `event.target.id` を `machine.threads.has` で確認しているが、`done` / `cancelAck` event は `event.parent` を持つ — parent thread が削除されたケースに対応できない可能性。`onChildDoneFromRunner` 内では `children.get(callId)` で undefined を弾くのでセーフだが、stale parent への dispatch を runner レベルで弾く処理は無い。実害は small (parent が消えていたら children も消えている前提)。
- **[D]** `for (const event ...)` ではなく `while (queue.length > 0) { shift() }` を使っている。Denque で OK。

### A.3 [machine/scope.ts](../typescript/packages/katari-runtime/src/machine/scope.ts)

- **[B?]** GC が `state.delegations` (External) と `state.apiDelegations` の args / value を **roots に含めない**。理屈上、ExternalThread が args として持つ closure value は thread が live なので thread.scopeId 経由でその scope は traceable... ではない。closure value を作った側のスコープは閉包のスコープではない。実際:
  - `value: closure` は `scopeId: thread.scopeId` (closure を作成した時の scope)
  - その closure を ExternalThread に渡した場合、ExternalThread は独自の `scopeId` を持つが、`args` は scope に書かれない (ExternalThread は scope を使わない)
  - GC root: `thread.scopeId`。caller の UserThread の scopeId は live なので、その親 chain は trace される。closure を作った agent UserThread は当該 closure を `setValueInScope` で書いてから FFI 呼び出しに使ったはず → scope.values にも入っている → trace される。
  - 結論: 大丈夫。但し "ExternalThread の args / RequestThread の args / handler body の args 経由でしか到達できない closure" は trace されない設計。
- **[D]** `getValueFromScope` 失敗時 plain Error を投げる。compiler バグ系なので Recoverable 化検討。

### A.4 [machine/thread/types.ts](../typescript/packages/katari-runtime/src/machine/thread/types.ts)

- **[D]** `Thread` (786 行) が template method + snapshot common helpers + ChildThread を 1 ファイルに含む。snapshot 関係を別ファイルに切り出せるが、循環参照を避けるため tradeoff。
- **[B]** `linkCommon` が `EMPTY_BOUNDARIES` を一旦詰めてから `boundaries = deserializeBoundaries(...)` で上書きする。`deserializeBoundaries` は thread map を見て解決するが、**初期 EMPTY_BOUNDARIES が中間状態として thread に詰まる** ので、もし resolve 中に他 thread が boundaries を読みに来たら一時的に null。同期的に linkAll する分には大丈夫だが、ややフラジャイル。
- **[S]** `InternalMutable<T>` cast が複数箇所で散在。snapshot mod の特異仕様だが、type system で readonly を緩めるしか手がない。

### A.5 [machine/thread/api.ts](../typescript/packages/katari-runtime/src/machine/thread/api.ts) — APIThread

- **[B]** `handleDelegateFromAPI` が同じ `delegationId` で 2 回呼ばれた時に **古い APIThread が孤立** する。`state.apiDelegations.set(delegationId, apiThread)` で上書きされるが、`state.threads` には古いものが残っている。ホントに来ないと信じるなら問題ないが、defensive に重複検出すべき。
- **[D]** `entryBlockId` が IR の任意の Block を指せる。`blockUser` (kind agent) でなくとも spawn できてしまうため、broken IR で奇妙な動作を起こす可能性。`createThreadFromBlock` は spawn してくれるが、`exitKindReturn` の boundary が立たない (UserThread agent でないと立てない) ため、`return` がエラーになる。
- **[I]** APIThread は cancellation と completion で `apiDelegations.delete + threads.delete` を直書きしているが、共通化されていない。

### A.6 [machine/thread/user.ts](../typescript/packages/katari-runtime/src/machine/thread/user.ts) — UserThread

- **[B]** `statementBindPattern` で refutable pattern が降ってきたとき plain `Error` を throw ([line:142](../typescript/packages/katari-runtime/src/machine/thread/user.ts#L142))。本来 compiler バグ由来なので個別 agent の問題として `RecoverableEngineError` に振るべき (現状は version 全体 poison)。
- **[B]** `statementExit` / `statementCont` で boundary が null だった場合 plain `Error` ([line:161](../typescript/packages/katari-runtime/src/machine/thread/user.ts#L161))。compiler が check していれば来ない。Recoverable 推奨。
- **[D]** `pushCallEvent` 内で `block.kind` を見て callBlock / callInline を切り替える。これは UserThread が IR の構造的 block を知っている必要があり、そこそこ広い責任。Lower 側で `callBlock`/`callInline` フラグを IR に乗せる方が綺麗 (が、IR の構造的 block kind から自明に決まるので冗長と判断したのだろう)。
- **[B?]** `args[param.label]` が `undefined` の時 scope に書き込まない。compiler が必ず provide することが前提だが、防御的に `NULL_VALUE` をデフォルト書きすべき (もしくは error)。

### A.7 [machine/thread/handle.ts](../typescript/packages/katari-runtime/src/machine/thread/handle.ts) — HandleThread

- **[B]** `onChildDone` の case `handlerBody` で plain `Error` ([line:277](../typescript/packages/katari-runtime/src/machine/thread/handle.ts#L277)): "handler body finished without break/next" は compiler バグ由来。Recoverable に。
- **[B]** `spawnHandlerBody` で handler が見つからなかった時 plain `Error` ([line:168](../typescript/packages/katari-runtime/src/machine/thread/handle.ts#L168))。RequestThread の handlers map から HandleThread を引き当てた段階で `block.handlers.find(...)` は必ず成功するはずだが、handlers 表と block.handlers の整合性ずれ (snapshot 不整合等) で起こりうる。Recoverable。
- **[B]** `findImmediateChildCallId` が見つからない時 plain `Error` ([line:574](../typescript/packages/katari-runtime/src/machine/thread/handle.ts#L574))。これは boundaries 設計上必ず祖先である hand があるはずなので invariant 違反 = Irrecoverable で正しい。
- **[D]** `nextCallId: CallId = 1` から始まる。callId 0 は main (`MAIN_CALL_ID`)。これを定数で表すのは OK だが、callId が `number` 型なため 1 と 0 の意味は code reading time にしかわからない。
- **[B?]** Sequential mode で `pendingActions` に thenClause を queue した状態で main target がまだ canceling 経路にいる場合の挙動が複雑。たとえば `break` で全 cancel → `pendingActions` に残っている thenClause は `finishCancelling` で `pendingReturn` 経路に乗ってしまうと無視される。コメント: "thenClause finished... cancel all remaining children" となっているので意図的 (break が thenClause をバイパス)。OK。

### A.8 [machine/thread/for.ts](../typescript/packages/katari-runtime/src/machine/thread/for.ts) — ForThread

- **[I]** `parallel: true` の for は throw する (line:104)。実装漏れ。
- **[D]** `iterableSnapshot` を constructor で固定する設計。snapshot に保存して restore も対応 (line:269 で legacy snapshot 互換 fallback あり)。OK。
- **[B]** `bindElementVars` が iter 元配列を毎回 lookup する代わりに `iterableSnapshot` から拾う ([line:347](../typescript/packages/katari-runtime/src/machine/thread/for.ts#L347))。OK だが mixed-radix 計算は左右どちらが outer かの semantics をコメントで補足している。可読性低めだが正しい。

### A.9 [machine/thread/external.ts](../typescript/packages/katari-runtime/src/machine/thread/external.ts) — ExternalThread

- **[I]** **タイムアウトが無い**。FFI が応答を返さなければ agent は永遠に running のまま。
- **[D]** `handleDelegateAckFromFFI` が unknown delegationId を silently absorb する設計。コメント記述 OK。idempotent 化を意図。OK。
- **[D]** `handleTerminateAckFromFFI` 同様に idempotent。

### A.10 [machine/thread/prim.ts](../typescript/packages/katari-runtime/src/machine/thread/prim.ts)

- **[D]** prim の switch (16 case) が hard-coded。`name` のレジストリを外部から差し込めるようにすると拡張性 ↑。「Built-in primitive registry」が Haskell 側の commit b0d16ac で追加されているので、TS 側もそれに追従するべき (Haskell との同期管理)。
- **[B?]** `eq` / `neq` の cast `args["left"]!` で `undefined` 注釈を非 null assertion で潰している。args に left/right が無い不正 IR で SIGSEGV 相当 (TypeScript なので runtime error)。RecoverableEngineError + 検査が望ましい。
- **[D]** `valueEquals(closure, closure)` が常に false。仕様としては OK (Haskell の `eq` も同じ)。

### A.11 [machine/thread/match.ts / ctor.ts / tuple.ts / array.ts / request.ts]

- **[D]** **TupleThread と ArrayThread の重複** (Phase 1 でも指摘): `collected` Map + `nextIndex` + sequential/parallel 分岐 + `emitDone` が同型。`CollectingChildThread` で抽出すべき。
- **[I]** RequestThread の snapshot 復元時の onCall 再発火 (snapshot.ts:188) が defensive すぎるとも書かれている。実際には現在の実装で RequestThread が pendingAskId === undefined で生き残るシナリオは無いが、コードは存在。

### A.12 [runtime/facade.ts](../typescript/packages/katari-runtime/src/runtime/facade.ts) — MachineHandle

- **[D]** `feedEvent` で任意の `MachineEvent` を注入可能。これは "future FFI executor 用" の hatch だが、from/to を任意指定できるため `delegate FFI→CORE` 等を直接ねじ込める (まだ未実装)。defensive 検証が無いので不正 event で panic する可能性。
- **[I]** `MachineHandle` が startAgent / cancelAgent / feedEvent / toSnapshot しか持たない。GC をユーザに見せていない。`forceGc()` のような explicit hook は将来必要。

### A.13 [runtime/snapshot.ts](../typescript/packages/katari-runtime/src/runtime/snapshot.ts)

- **[D]** Pass 1 / Pass 2 / Pass 3 (pass 3 = RequestThread の onCall 再発火) という多段構造。十分にコメント。OK。
- **[B?]** `delegations` / `apiDelegations` の復元時に instanceof 検査をしているが、broken snapshot で `not pointing to ExternalThread` が出ると plain `Error` で throw → 全 version load 失敗。Recovery がこの error を catch して snapshot 削除する流れになっているので隔離されている。OK。
- **[B?]** `MachineState.queue` が snapshot の対象外 (= 復元時は空)。コメント: "applyEvent boundary では空" と claim。つまりapplyEvent throw 後に snapshot を取ってしまうと空のキューが永続化されてしまう。api-server の rollback path は **applyEvent 前の snapshot** を使うので問題ない。
- **[B?]** `MachineState.lastGcScopeCount` が snapshot 対象外。復元後の GC 閾値が 0 から始まるため、最初の applyEvent で確実に GC が走る (副作用なし)。OK。

### A.14 [runtime/errors.ts](../typescript/packages/katari-runtime/src/runtime/errors.ts)

- **[D]** `RecoverableEngineError` に optional `delegationId` がある。現状未使用 (caller が判断)。
- **[D]** `IrrecoverableEngineError` を export してるが、コードベース内で **誰も throw していない**。"plain Error" が irrecoverable 扱いになる慣習を期待する設計だが、明示性が低い。

### A.15 [runtime/logger.ts](../typescript/packages/katari-runtime/src/runtime/logger.ts)

- OK。十分小さい。

## B. katari-api-server

### B.1 [bin.ts](../typescript/packages/katari-api-server/src/bin.ts)

- **[B?]** `setTimeout(..., 30_000).unref()` で hard exit。但し `.unref()` してるので shutdown 完了で exit されない場合に supervisor 任せ。OK。
- **[D]** 環境変数の数が増えてきている (`DATABASE_URL`, `PORT`, `LOG_LEVEL`, `KATARI_API_KEY`, `KATARI_MACHINE_CACHE_MAX`)。設定オブジェクトの builder にまとめると見通し良い。
- **[I]** `KATARI_RATE_LIMIT_*` 系 env var が無い (default constant 60/1)。production tunable 化推奨。

### B.2 [registry.ts](../typescript/packages/katari-api-server/src/registry.ts)

- **[L]** `mutexes` Map にエントリを追加するだけで削除しない (`evict` でも残す)。長期間動かして version が累積するとメモリ圧 (1 entry = 数百バイト程度なので深刻ではないが、1 万 version で 1MB 程度はある)。
- **[D]** `replaceHandle` は `agent-service` 専用 hatch。registry の本質的な API ではない。registry は cache に専念し、`MachineRebuilder` のような別クラスを差し込むべき。
- **[D]** `inFlight` で同時 acquire collapse は良い実装。但し loadHandle が throw した場合、inFlight を delete するため次の acquire は再 load を試みる → 持続的に失敗する snapshot に対しては毎リクエスト毎に load 試行 = 無駄。short-term cache (`recently failed`) があると良い。

### B.3 [services/agent-service.ts](../typescript/packages/katari-api-server/src/services/agent-service.ts)

- **[B] CRITICAL** `versionedRollback` の `void this.rebuildAndCache(versionId, snap).catch(...)` ([line:330](../typescript/packages/katari-api-server/src/services/agent-service.ts#L330))。**mutex を抜けた後** に async rebuild を走らせる設計だが:
  1. mutex.runExclusive が即終了 (rebuild promise は in-flight)
  2. caller の `await mutex.runExclusive` が return
  3. 直後に別のリクエストが mutex.runExclusive で acquire → registry から **古い (poisoned) handle** を取得
  4. 古い handle で applyEvent → 不正動作
  5. その後 rebuild が完了して cache に新しい handle を入れるが、もう手遅れ
  
  **修正必須**: rebuildAndCache を `await` すること。あるいは startAgent の catch ブロックを async/await で待つ。

- **[B]** `routeOutbound` でアウトバウンド event を見て agent.setState する。但し:
  - `delegateAck` from CORE→API: setState(succeeded) with expectedState=running
  - `terminateAck` from CORE→API: setState(cancelled) with expectedState=cancelling
  - **だが**: agent が "error" 状態に poison 済みなのに engine がまだ知らずに ack を投げてくる場合、expectedState 不一致で no-op になり info ログだけ。設計は OK。

- **[B]** `routeOutbound` 内で `findByDelegationId` 失敗時 `warn` log のみで continue。設計上 unknown delegation なのは普通起きないが、ありえる ([api.ts:75](../typescript/packages/katari-runtime/src/machine/thread/api.ts#L75) で APIThread の delete が startAgent insert と非同期...いや、insert は startAgent の tx 内にあるので順序保証されている)。OK だが警告ログは適切。

- **[D]** `poison()` のロジックが複雑。`agents.insert` を最初に試して duplicate-key で fall through、その後 `markAllRunningAsError` → `snapshots.delete` → `evict`。各 step idempotent なので OK だが、`withTransaction` で囲まれていないので **部分失敗の可能性** (snapshot 削除前に DB connection 切れたら、次回 boot で snapshot から corrupt state を復活させる)。recovery がそれをまた捕捉して snapshot 削除する構造があるので最終的には安全。

- **[B]** `EntryNotFoundError` で `versionedRollback` を呼ぶ ([line:115](../typescript/packages/katari-api-server/src/services/agent-service.ts#L115))。但し EntryNotFound は **applyEvent の冒頭で entries lookup 失敗で throw** されるので、engine state は **mutate されていない**。rollback 不要 (handle はクリーン)。実害は無い (rebuild 結果が同一) が無駄。

- **[D]** **`AgentService` に集中しすぎ**: 402 行で 5 種の責務 (Phase 1)。

### B.4 [recovery.ts](../typescript/packages/katari-api-server/src/recovery.ts)

- **[B] CRITICAL** `cancelling` 状態の agent を resume しようと `agents.cancelAgent(row.id)` を呼ぶが ([line:94](../typescript/packages/katari-api-server/src/recovery.ts#L94))、`cancelAgent` の中で:
  1. `getAgent(agentId)` で row を取得 (state=cancelling)
  2. `isTerminal(row.state)` は false → 続行
  3. `mutex.runExclusive` 内で `tx.agents.setState(agentId, { state: "cancelling" }, { expectedState: "running" })`
  4. **expectedState=running なので state=cancelling と不一致 → transitioned=false**
  5. `if (!transitioned) return;` で early return
  6. **engine への `handle.cancelAgent` が呼ばれない**
  
  → 結果: 再起動後 cancelling だった agent は永遠に cancelling のまま (engine 側は terminate イベントを受け取らない)。**致命**。
  
  修正: recovery 用に「engine への terminate を直接打つ」専用パスが必要。あるいは `cancelAgent` に `expectedState` を `cancelling` も許容する flag を追加。

- **[B]** ページングロジックが offset 方式で `limit` も DB 側 cap (500) と同じ。`rows.length < PAGE_SIZE` で break するが、500 件ちょうどの場合は次ページを試す → 毎回 cap した結果が 500 で永遠ループ可能性 (現実には offset 進むのでいずれ 0 件ヒットして抜ける)。OK。

- **[D]** Snapshot がない version で agent state を全部 error にするのは妥当。但しこのケースで snapshot delete も同様に呼ぶべき (現在は呼んでいない、ファイルシステム側に取り残し)。

### B.5 [storage/pg.ts](../typescript/packages/katari-api-server/src/storage/pg.ts)

- **[B] CRITICAL** `PostgresStorage.withTransaction` 内で構築する `txStorage` の `withTransaction` が **`this.withTransaction.bind(this)`** ([line:335](../typescript/packages/katari-api-server/src/storage/pg.ts#L335))。`this.sql` (= 元の pool 接続) を使うため、**ネストした transaction が外側 tx に savepoint で参加せず、別の独立した BEGIN/COMMIT を発行**する。コメント「postgres' sql.begin handles that internally」と矛盾。
  
  修正: 内側の `txSql` を bind した closure を渡すべき。例:
  ```ts
  withTransaction: <U>(innerFn: (innerTx: Storage) => Promise<U>) =>
    txSql.savepoint(async (sp) => {
      const inner = buildTxStorage(sp);
      return innerFn(inner);
    });
  ```

- **[B]** `setState` の `joined = sets.reduce((acc, cur, i) => ...)` で `i === 0 ? cur : sql\`${acc}, ${cur}\`` を組み立てているが、`postgres` driver の template literal joining に慣れていないと安全性が分かりにくい。直接 `sql.join` 系を使うか、各 case を if-elseif で書き下す方が監査容易。
- **[D]** `asJson<T>(value: T): never { return value as never; }` の cast helper。1 箇所に閉じ込めているのは良いが、本質は `unknown` への cast でいいはず。`never` は誤用感がある。

### B.6 [storage/memory-storage.ts](../typescript/packages/katari-api-server/src/storage/memory-storage.ts)

- **[D]** `withTransaction` の rollback が `this` の private map を `as unknown as { rows: ... }` で書き換える。フラジャイル。Repo 側に `_capture()` / `_restore(state)` を生やしておく方がカプセル化的に良い。
- **[D]** `JSON.parse(JSON.stringify(value))` で deep clone しているが、`Date` や `Map` などは保存できない (現状の type には含まれないので問題なし)。`structuredClone` の方が一般的だが、value にも互換あり。

### B.7 [routes/]

- **[D]** `routes/agent-definition.ts` の URL design `/agent-definition/:versionId/:qualifiedName`。`qualifiedName` は内部に `.` を含むので、Hono が URL pattern として match するが、エンコードしないと `module.name` の `.` を path セパレータにしないか (Hono の挙動次第)。`decodeURIComponent` のみで OK と設計しているが、Hono のパラメタ抽出が `:foo` のパターンマッチで `.` も含むかは Hono の version 仕様依存。
- **[B?]** `routes/module.ts` GET `/:versionId` が IRModule を返さない。これは意図的 ([line:43-44](../typescript/packages/katari-api-server/src/routes/module.ts#L43)) だが、debug 用にすら IR が見えないのは不便。
- **[I]** `DELETE /module/:versionId` が無い。長期運用で必要。
- **[I]** `routes/agent.ts` に `GET /agent/:id/result` 等の専用 endpoint が無い。state=succeeded の result を取るには row 全体を取得する必要がある。
- **[I]** Health checks: liveness (`/healthz`) は OK。readiness は DB connectivity だが、registry の状態 (load 失敗 version 数等) は出していない。
- **[D]** `auth.ts` の `constantTimeEqual` がコメント通り length leak だが、length が一定の API key なら問題なし。OK。

### B.8 [middleware/rate-limit.ts](../typescript/packages/katari-api-server/src/routes/middleware/rate-limit.ts)

- **[D]** `x-forwarded-for` の "leftmost hop" を信頼するのは proxy 信頼前提。同 IP の複数クライアントが同じ bucket を共有する。許容内。
- **[B?]** `bucket = buckets.get(key) ?? { tokens: capacity, lastRefillMs: now }` で fallback して、その後常に `set(key, bucket)` する。但し refill 計算は `tokens + elapsedSec * refillPerSecond`。新規 bucket は `tokens: capacity` で作るので、「初リクエスト直後に refill = 0 (elapsed = 0)」、「2 回目以降は時間経過分追加」。OK。

### B.9 [metrics.ts](../typescript/packages/katari-api-server/src/metrics.ts)

- **[I]** `applyEventDuration.observe(...)` 系のコール元が現状のコードに **存在しない** (作りっぱなし)。AgentService.startAgent / cancelAgent の mutex.runExclusive を計測するように wire 必要。
- **[I]** `agentStartTotal.inc()` も呼ばれていない (route 側で increment するべき)。
- **[I]** `machinesLoaded` gauge も registry が増減を通知しない。

## C. 横断的な観察

### C.1 Snapshot の整合性

- `applyEvent` boundary でしか snapshot を取らない設計は明確。
- Snapshot に含まれない state: queue, pendingOutEvents, lastGcScopeCount, logger。**全て applyEvent boundary では transient or 復元可能**。OK。
- Snapshot に含めるが復元できないケース: closure 内の `scopeId` が trace 漏れで GC 済みだったら → restore 時に該当 scope が無い。**[B?]** restore 時の検証が無いので silent corruption の可能性。

### C.2 Recovery の不整合

- `state == cancelling` の agent を resume できない (上記 B.4)。
- `state == running` で snapshot に対応 ExternalThread が無いケース → engine 復元自体は通るが、agent は永遠に running のまま (FFI executor 未実装なため)。
- `state == running` で snapshot に対応 APIThread が無いケース → 以前の applyEvent で agent が succeeded して状態遷移する直前にクラッシュ → snapshot は agent succeeded 後 ('cause apply完了直前) なので APIThread は消えている。 agentRow は updateBefore のため running のまま。次の cancel 等で違和感。**[B]** → row.state と engine の整合性が取れていない可能性。

### C.3 Docker Compose etc.

- `/home/yukikurage/projects/katari/docker-compose.yml` にどんな構成があるかは未確認 (今回スコープ外)。

### C.4 テスト網羅

- runtime tests (12 件): cancel-race, error-taxonomy, external-idempotent, gc, handle, match, prim, request-thread-snapshot, snapshot, for, array-tuple, bind-pattern。よくカバー。
- api-server tests (8 件): auth-and-rate-limit, cancel-e2e, compiler-roundtrip, concurrent-registry, end-to-end, poison, recoverable-error, snapshot-recovery。recovery の cancelling resume バグは多分 test されていない (要確認)。

## D. 評価サマリ

### Critical bugs (即修正が必要)

| # | 場所 | 内容 | 影響 |
|---|---|---|---|
| 1 | [recovery.ts:94](../typescript/packages/katari-api-server/src/recovery.ts#L94) | `cancelling` 状態の resume が動かない | 再起動後 cancelling agent が永遠に取り残される |
| 2 | [agent-service.ts:330](../typescript/packages/katari-api-server/src/services/agent-service.ts#L330) | `versionedRollback` の async fire-and-forget | rollback 完了前に別リクエストが古い handle を掴むレース |
| 3 | [pg.ts:335](../typescript/packages/katari-api-server/src/storage/pg.ts#L335) | nested withTransaction が savepoint を貼らない | transaction 入れ子の atomicity 喪失 |

### Significant gaps (機能不足)

- FFI executor 未実装 → 全ての `ext` 呼び出し agent が永久 running
- ExternalThread タイムアウト無し
- parallel for 未実装
- Module DELETE エンドポイント無し
- Metrics の wire 漏れ (Counter/Gauge/Histogram が定義されているが increment/observe されていない)

### Layer / 責務違反

- machine/ → runtime/ への逆参照 (errors.ts, logger.ts)
- AgentService 責務肥大 (5 種の責務)
- MachineRegistry に replaceHandle が混在
- Public API 過剰露出 (Thread サブクラス全部)

### Code quality smells

- TupleThread / ArrayThread 重複
- Snapshot serialize/restore boilerplate (Object.create + InternalMutable cast)
- args["left"]! の non-null assertion 散在
- 多数の plain Error throw (Recoverable に降格すべき)

### 良い点 (refactor 後も保つべき)

- Boundaries の slot 化 + 型 narrow
- handlers map の HandleThread 型 narrow
- Template method パターン (Thread.onChildDoneFromRunner 等)
- pattern.ts による tryMatch 共有
- per-version mutex + Storage transaction の組合せ
- inFlight Map による同時 acquire collapse
- Auth の constant-time compare
- frozen NULL_VALUE singleton
