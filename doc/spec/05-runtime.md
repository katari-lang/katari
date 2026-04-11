# KATARI Language Specification - Runtime Execution Model

本仕様書は Katari IR (v0.2, Thread ベース) を解釈・実行するランタイムの実装ガイドである。Rust ランタイム開発者向けに、Thread 状態マシン・signal 伝搬・handle/for/par アルゴリズム・request ルーティング・協調イベントループの全動作を定義する。

## 1. 実行モデル概要

### 1.1 Thread = 状態マシン

Katari ランタイムの**実行単位は thread** である。各 thread は独立した状態マシンとして動作し、`IRThread` に定義された命令列を PC (program counter) で順次実行する。

thread は**ツリー構造**を形成する。parent thread が child thread を生成し、child の完了を待ち、signal を処理する。具体的には:

- `IHandle dst hid` → HANDLER_TARGET child thread を生成
- `IFor dst fid` → FOR_BODY child thread を生成
- `IPar dst [t1,t2,...]` → 複数の BLOCK child thread を生成
- `ICall dst agentId args` → child **agent** を生成 (agent 境界)

thread が child を生成すると自身は **Suspended** 状態に遷移し、child の完了 signal を受けて再開する。

### 1.2 Agent = Thread のコンテナ

Agent は thread ツリーのコンテナである。1 つの agent は以下を持つ:

- **root thread**: `IRAgentDef.entry` で参照される FN_BODY thread
- **vars**: `HashMap<VarId, Value>` — 全 thread が共有する変数マップ
- **threads**: 現在アクティブな全 thread の状態

Agent は ICall による agent 呼び出しの**コンテキスト境界**を定義する。callee agent は caller の変数に一切アクセスできない。引数は値渡しで callee の parameter vars にコピーされる。

### 1.3 Scope Chain (変数解決)

`VarId` はモジュール全体でユニークである。同一 agent 内の全 thread は単一の `vars: HashMap<VarId, Value>` を共有する。そのため、child thread は parent thread の変数を自然に読み取れる (scope chain は vars マップの共有により暗黙的に実現される)。

**重要**: 変数の**書き込み**は原則として自身の命令で行う。child thread から parent thread の変数を変更するには、signal に含まれる `mutations` (例: `IContinue`, `IForContinue`) を使用する。parent thread が mutations を受け取って vars マップを更新する。

### 1.4 協調イベントループ

各 agent は協調的 (cooperative) なイベントループモデルで動作する。thread は以下の**suspension point**で実行を中断する:

- `IHandle` → child thread (HANDLER_TARGET) の実行待機
- `IFor` → child thread (FOR_BODY) の反復実行待機
- `IPar` → 複数 child thread (BLOCK) の完了待機
- `ICall` → child agent の完了待機
- `IRequest` → handler からの reply 待機 (agent 外に転送された場合)

suspension point 以外では、thread は中断なく命令を順次実行する。

## 2. データ構造

### 2.1 ThreadState

```rust
struct ThreadState {
    thread_id: ThreadId,
    kind: ThreadKind,
    pc: u32,                         // 現在の命令位置 (0-origin)
    status: ThreadStatus,
    parent: Option<ThreadId>,        // 親 thread (root は None)

    // Handle scope: この thread が IHandle を実行して管理中の handle
    handle_scope: Option<HandleScope>,

    // Thread-local request queue
    // (handle の handler 実行中に到着した request を蓄積)
    request_queue: VecDeque<PendingRequest>,

    // この thread から見て handleable な RequestId の集合
    // (自身の handle_scope + 全祖先の handle_scope の union + 親 agent 経由分)
    available_requests: HashSet<RequestId>,
}
```

### 2.2 ThreadStatus

```rust
enum ThreadStatus {
    Running,                     // 命令を実行中
    Suspended(SuspendReason),    // child thread/agent の完了待機中
    Completed(Signal),           // 完了済み
}
```

### 2.3 SuspendReason

```rust
enum SuspendReason {
    Handle {
        handle_def_id: HandlerId,
        dst: VarId,
    },
    For {
        for_def_id: ForId,
        current_index: u32,
        min_length: u32,
        dst: VarId,
    },
    Par {
        branch_threads: Vec<ThreadId>,
        results: Vec<Option<Value>>,  // 完了順に格納、未完了は None
        dst: VarId,
    },
    Call {
        child_agent_id: String,
        dst: VarId,
    },
    Request {
        // 親 agent に転送された IRequest の reply 待機
        request_id: String,
        dst: VarId,
    },
}
```

### 2.4 HandleScope

```rust
struct HandleScope {
    handle_def_id: HandlerId,
    dst: VarId,
    phase: HandlePhase,
}

enum HandlePhase {
    // HANDLER_TARGET body を実行中
    RunningBody {
        body_thread: ThreadId,
    },
    // body を中断して REQUEST_HANDLER を実行中
    RunningHandler {
        body_thread: ThreadId,      // 中断されている body
        handler_thread: ThreadId,   // 実行中の handler
        requester: RequestOrigin,   // reply 先
    },
    // body 完了後の then 節を実行中
    RunningThen {
        then_thread: ThreadId,
    },
}

struct RequestOrigin {
    from_agent_id: String,
    from_agent_where: Url,
    request_id: String,        // 冪等性のための ID
}
```

`phase` で handle の実行フェーズを追跡する。body 実行中に request がキャッチされると `RunningHandler` に遷移する。

### 2.5 HandleState

```rust
struct HandleState {
    state_vars: HashMap<VarId, Value>,
}
```

handle の状態変数を保持する。`IContinue` の mutations で更新される。

### 2.6 AgentState

```rust
struct AgentState {
    agent_id: String,
    agent_def_id: AgentId,

    // 全 thread が共有する変数マップ
    vars: HashMap<VarId, Value>,

    // Handle 状態変数 (handler ID → state)
    handle_states: HashMap<HandlerId, HandleState>,

    // 全 thread をフラット管理 (parent 参照でツリーを構成)
    threads: HashMap<ThreadId, ThreadState>,

    // Root thread (FN_BODY)
    root_thread: ThreadId,

    // Inter-agent
    parent_agent_id: String,
    parent_agent_where: Url,

    // child_agent_id → spawn した thread ID
    children: HashMap<String, ThreadId>,

    // 親 agent から受け継いだ handleable request 集合
    parent_available_requests: HashSet<RequestId>,
}
```

**`children` マップ**: 子 agent ID から、それを spawn した thread への参照。外部 request のルーティング起点の特定に使用する。

### 2.7 Value

ランタイム値は JSON 互換:

```rust
enum Value {
    Null,
    Boolean(bool),
    Integer(i64),       // 任意精度が理想だが、i64 で実装可能
    Number(f64),        // IEEE 754
    String(String),     // UTF-8
    Array(Vec<Value>),
    Object(HashMap<String, Value>),
}
```

### 2.8 Signal

thread の実行は 6 種類の signal のいずれかで終了する:

```rust
enum Signal {
    Normal(Value),                           // IComplete
    FnReturn(Value),                         // IReturn
    HandleBreak(Value),                      // IHandleBreak
    Continue(Value, Vec<(VarId, VarId)>),    // IContinue
    ForBreak(Value),                         // IForBreak
    ForContinue(Vec<(VarId, VarId)>),        // IForContinue
}
```

## 3. Thread 実行

### 3.1 命令実行ループ

thread の実行は以下のループで行われる:

```
fn execute_thread(agent: &mut AgentState, thread_id: ThreadId):
    loop:
        let thread = &mut agent.threads[thread_id]
        let ip = thread.pc
        let instr = lookup_instruction(thread.thread_id, ip)
        thread.pc = ip + 1  // デフォルトで次命令へ

        match instr:
            // Terminal instructions → signal を返して thread 終了
            IComplete(val) =>
                thread.status = Completed(Signal::Normal(agent.vars[val]))
                return
            IReturn(val) =>
                thread.status = Completed(Signal::FnReturn(agent.vars[val]))
                return
            IHandleBreak(val) =>
                thread.status = Completed(Signal::HandleBreak(agent.vars[val]))
                return
            IContinue(val, mutations) =>
                thread.status = Completed(Signal::Continue(agent.vars[val], mutations))
                return
            IForBreak(val) =>
                thread.status = Completed(Signal::ForBreak(agent.vars[val]))
                return
            IForContinue(mutations) =>
                thread.status = Completed(Signal::ForContinue(mutations))
                return

            // Control flow → PC を変更
            IJump(target) => thread.pc = target
            IBranch(cond, t, f) =>
                thread.pc = if agent.vars[cond].is_truthy() { t } else { f }
            ISwitch(val, cases, default) =>
                thread.pc = find_matching_case(agent.vars[val], cases, default)

            // Suspension points → thread を suspend して child 管理へ
            IHandle(dst, hid) => handle_ihandle(agent, thread_id, dst, hid)
            IFor(dst, fid) => handle_ifor(agent, thread_id, dst, fid)
            IPar(dst, tids) => handle_ipar(agent, thread_id, dst, tids)
            ICall(dst, aid, args) => handle_icall(agent, thread_id, dst, aid, args)
            IRequest(dst, rid, args) => handle_irequest(agent, thread_id, dst, rid, args)

            // 通常の命令 → vars を更新して次命令へ
            ILoadConst(v, c) => agent.vars[v] = load_const(c)
            ILoadNull(v) => agent.vars[v] = Value::Null
            IMove(dst, src) => agent.vars[dst] = agent.vars[src].clone()
            // ... (他の命令)
```

### 3.2 PC 管理

- 各 thread の `pc` は命令列内の絶対位置 (0-origin)
- 通常の命令は実行後に PC を +1 する
- `IJump`, `IBranch`, `ISwitch` は PC を指定位置に設定する
- Terminal 命令 (`IComplete`, `IReturn`, `IHandleBreak`, `IContinue`, `IForBreak`, `IForContinue`) は signal を返して thread を終了する
- Suspension 命令 (`IHandle`, `IFor`, `IPar`, `ICall`, `IRequest`) は thread を suspend する。再開時は**次の命令** (pc は既に +1 済み) から実行される

### 3.3 変数アクセス

thread 内の命令が参照する `VarId` は、agent の `vars` マップから直接取得する:

- `VarId` はモジュール全体でユニークなので、scope chain は vars マップの共有により自然に実現される
- child thread で生成された変数は parent thread からも可視 (同じ vars マップ内)
- ただし agent 境界 (`ICall`) を跨いだアクセスは不可能

## 4. Signal 伝搬

thread の実行は 6 種類の signal のいずれかで終了する。signal は thread を起動した parent thread で処理される。

### 4.1 Signal 一覧

| Signal | 発行命令 | 説明 |
|--------|----------|------|
| `Normal(value)` | `IComplete` | thread 正常完了 |
| `FnReturn(value)` | `IReturn` | ソースの `return` 文 |
| `HandleBreak(value)` | `IHandleBreak` | handle scope 脱出 |
| `Continue(value, mutations)` | `IContinue` | request handler → handle 復帰 |
| `ForBreak(value)` | `IForBreak` | for loop 脱出 |
| `ForContinue(mutations)` | `IForContinue` | for body → 次イテレーション |

### 4.2 Signal の処理先

| Signal | 停止地点 | 備考 |
|--------|---------|------|
| Normal | 直接の parent thread | parent の suspend reason に応じて処理 |
| FnReturn | root thread (FN_BODY) | 全ての中間 thread を巻き戻し |
| HandleBreak | handle を管理する parent thread | handle scope を脱出 |
| Continue | handle を管理する parent thread | REQUEST_HANDLER → HANDLER_TARGET 再開 |
| ForBreak | for を管理する parent thread | for loop を脱出 |
| ForContinue | for を管理する parent thread | FOR_BODY → 次イテレーション |

### 4.3 FnReturn の巻き上げ

`IReturn` が発行されると、thread ツリーを root (FN_BODY) まで巻き上げる:

```
fn propagate_fn_return(agent: &mut AgentState, thread_id: ThreadId, value: Value):
    let mut current = thread_id
    loop:
        let parent = agent.threads[current].parent
        match parent:
            None:
                // root thread に到達 → agent 正常完了 (return)
                agent_return(agent, value)
                return
            Some(parent_id):
                // 中間 thread をクリーンアップ
                cleanup_thread(agent, parent_id)
                current = parent_id
```

巻き上げ中に通過する各 thread について:
- **Handle を管理中**: handle_scope をクリア、handle_states から除去、body thread を terminate
- **For を管理中**: body thread を terminate
- **Par を管理中**: 全 branch thread を terminate
- **ICall で待機中**: child agent に terminate を送信

巻き上げ中に通過する全てのスコープ内の生存中の child agent に対して terminate を送信すること。

### 4.4 HandleBreak の伝搬

`IHandleBreak` は REQUEST_HANDLER thread 内でのみ発行される。signal は handle を管理する parent thread で処理される (第 5 章参照)。

HandleBreak が handle を管理する parent thread に到達するまでに中間 thread (例: for の内部で request が handle された場合) がある場合、それらは FnReturn と同様にクリーンアップされる。

## 5. Handle 実行アルゴリズム

### 5.1 IHandle の実行

thread A が `IHandle dst hid` を実行した際の処理:

```
fn handle_ihandle(agent, thread_a_id, dst, hid):
    let handle_def = lookup_handle_def(hid)

    // 1. State 変数を初期化
    for i in 0..handle_def.state_vars.len():
        let state_var = handle_def.state_vars[i]
        let init_var = handle_def.state_inits[i]
        agent.handle_states[hid].state_vars[state_var] = agent.vars[init_var]

    // 2. HANDLER_TARGET thread B を子として作成
    let body_tid = handle_def.body
    create_child_thread(agent, body_tid, parent=thread_a_id, params=[])

    // 3. HandleScope を設定
    agent.threads[thread_a_id].handle_scope = Some(HandleScope {
        handle_def_id: hid,
        dst: dst,
        phase: HandlePhase::RunningBody { body_thread: body_tid },
    })

    // 4. 子孫の available_requests を更新
    update_available_requests(agent, body_tid)

    // 5. Thread A を suspend
    agent.threads[thread_a_id].status = Suspended(Handle { handle_def_id: hid, dst })

    // 6. Thread B の実行を開始
    execute_thread(agent, body_tid)
    // → B が完了またはsuspendしたら、signal を処理
```

注意: `state_inits` の各 `VarId` は `IHandle` の**前**に配置された命令列で既に評価済みの変数を指す。コンパイラは handle パラメータの初期化式を `IHandle` の前に通常の命令としてコンパイルする。

### 5.2 Body 実行中の Request キャッチ

body thread B (またはその子孫) が `IRequest` を実行し、request ルーティング (第 8 章) により thread A がキャッチした場合:

```
fn handle_request_in_scope(agent, thread_a_id, handler_tid, request):
    let scope = &mut agent.threads[thread_a_id].handle_scope

    match scope.phase:
        RunningBody { body_thread }:
            // 1. State 変数を handler の params にコピー
            let hid = scope.handle_def_id
            for (state_var, value) in agent.handle_states[hid].state_vars:
                agent.vars[state_var] = value

            // 2. Request args を handler の params にバインド
            let handler_thread = lookup_ir_thread(handler_tid)
            for (param, arg) in zip(handler_thread.params, request.args):
                agent.vars[param] = arg

            // 3. Phase を RunningHandler に遷移
            create_child_thread(agent, handler_tid, parent=thread_a_id, params=[])
            scope.phase = RunningHandler {
                body_thread,
                handler_thread: handler_tid,
                requester: RequestOrigin {
                    from_agent_id: request.from_agent_id,
                    from_agent_where: request.from_agent_where,
                    request_id: request.request_id,
                },
            }

            // 4. Handler thread を実行
            execute_thread(agent, handler_tid)

        RunningHandler { .. }:
            // Handler 実行中 → queue に追加 (非再入)
            agent.threads[thread_a_id].request_queue.push_back(request)
```

### 5.3 REQUEST_HANDLER の Signal 処理

REQUEST_HANDLER thread C が完了した際の処理:

**Continue(value, mutations)**:
1. mutations を適用: 各 `(stateVar, newValVar)` について `handle_states[hid][stateVar] = vars[newValVar]`
2. requester に value を reply する
3. handler thread を破棄
4. phase を `RunningBody { body_thread }` に戻す
5. request_queue に pending request があれば次を処理
6. なければ body thread B の実行を再開する

**HandleBreak(value)**:
1. body thread B を terminate する (B の子孫も再帰的に)
2. `vars[dst] = value` を設定する
3. `handle_scope` を None にクリアする
4. `handle_states[hid]` を除去する
5. **then 節は実行しない**
6. thread A を再開 (IHandle の次の命令から)

**Normal(value)** (well-formed IR では通常発生しない):
- `Continue(value, [])` として扱う (暗黙の continue、mutations なし)

**FnReturn(value)**:
- handle scope をクリーンアップし、FnReturn を上位に伝搬する

### 5.4 Body の正常完了

HANDLER_TARGET thread B が `Normal(value)` で完了した場合:

```
// then 節がある場合
if let Some(then_tid) = handle_def.then:
    create_child_thread(agent, then_tid, parent=thread_a_id,
                        params=[value])  // body の結果を param にバインド
    scope.phase = RunningThen { then_thread: then_tid }
    execute_thread(agent, then_tid)
    // then thread の Normal 結果を handle の結果とする

// then 節がない場合
else:
    vars[dst] = value
    handle_scope = None
    handle_states.remove(hid)
    // thread A を再開
```

### 5.5 Body からの FnReturn

HANDLER_TARGET thread B が `FnReturn(value)` で完了した場合:
- handle_scope をクリアし、handle_states[hid] を除去する
- FnReturn signal を上位に伝搬する (第 4.3 節)

## 6. For 実行アルゴリズム

### 6.1 IFor の実行

thread A が `IFor dst fid` を実行した際の処理:

```
fn handle_ifor(agent, thread_a_id, dst, fid):
    let for_def = lookup_for_def(fid)

    // 1. State 変数を初期化
    for i in 0..for_def.state_vars.len():
        let state_var = for_def.state_vars[i]
        let init_var = for_def.state_inits[i]
        agent.vars[state_var] = agent.vars[init_var]

    // 2. 全配列の最小長を計算
    let min_len = for_def.arrays.iter()
        .map(|arr_var| agent.vars[arr_var].as_array().len())
        .min()
        .unwrap_or(0)

    // 3. Thread A を suspend
    agent.threads[thread_a_id].status = Suspended(For {
        for_def_id: fid,
        current_index: 0,
        min_length: min_len,
        dst,
    })

    // 4. 最初のイテレーションを開始 (min_len > 0 の場合)
    if min_len > 0:
        start_for_iteration(agent, thread_a_id, fid, 0)
    else:
        // 空配列 → 直接 then 節または完了
        finish_for(agent, thread_a_id, fid, dst)
```

### 6.2 各イテレーション

```
fn start_for_iteration(agent, thread_a_id, fid, index):
    let for_def = lookup_for_def(fid)

    // Element 変数をバインド
    for i in 0..for_def.iter_vars.len():
        agent.vars[for_def.iter_vars[i]] =
            agent.vars[for_def.arrays[i]].as_array()[index]

    // FOR_BODY thread を子として作成
    let body_tid = for_def.body
    create_child_thread(agent, body_tid, parent=thread_a_id,
                        params=for_def.iter_vars)

    // Body thread を実行
    execute_thread(agent, body_tid)
```

### 6.3 FOR_BODY の Signal 処理

**ForContinue(mutations)**:
1. mutations を適用: 各 `(stateVar, newValVar)` について `vars[stateVar] = vars[newValVar]`
2. index をインクリメント
3. `index < min_length` なら次のイテレーションを開始
4. 全イテレーション完了なら finish_for へ

**Normal(value)** (body が IComplete で終了):
- 暗黙の `ForContinue([])` として扱う (mutations なし)

**ForBreak(value)**:
1. `vars[dst] = value` を設定する
2. **then 節は実行しない**
3. thread A を再開

**FnReturn(value)**:
- for をクリーンアップし、FnReturn を上位に伝搬する

**HandleBreak(value)**:
- for をクリーンアップし、HandleBreak を上位に伝搬する

### 6.4 全イテレーション完了 (finish_for)

```
fn finish_for(agent, thread_a_id, fid, dst):
    let for_def = lookup_for_def(fid)

    if let Some(then_tid) = for_def.then:
        // FOR_THEN thread を子として作成 (params なし)
        create_child_thread(agent, then_tid, parent=thread_a_id, params=[])
        execute_thread(agent, then_tid)
        // then の Normal 結果を for の結果とする
    else:
        agent.vars[dst] = Value::Null
        // thread A を再開
```

### 6.5 空配列

min_length が 0 の場合、FOR_BODY は一度も実行されず、直接 finish_for に進む。state 変数は初期値のままで then 節が実行される。

### 6.6 複数イテレータ (zip)

複数の `let` バインディング (`iterVars`/`arrays` が複数) がある場合でも、IR レベルでは**単一の for loop** として表現される。全配列の同一インデックスの要素が同時にバインドされる (zip 相当)。ネストされた直積ループではない。

## 7. Par 実行アルゴリズム

### 7.1 IPar の実行

thread A が `IPar dst [t1, t2, ...]` を実行した際の処理:

```
fn handle_ipar(agent, thread_a_id, dst, tids):
    // 1. 各 BLOCK thread を子として作成
    let branch_threads = Vec::new()
    for tid in tids:
        create_child_thread(agent, tid, parent=thread_a_id, params=[])
        branch_threads.push(tid)

    // 2. Thread A を suspend
    agent.threads[thread_a_id].status = Suspended(Par {
        branch_threads: branch_threads.clone(),
        results: vec![None; branch_threads.len()],
        dst,
    })

    // 3. 全 branch を実行 (agent 内スケジューリング)
    schedule_par_branches(agent, branch_threads)
```

### 7.2 結果収集

各 branch thread が `Normal(value)` で完了したら:
1. 定義順の results 配列に value を格納
2. 全 branch が完了したら `vars[dst] = Array(results)` を設定し、thread A を再開

### 7.3 Signal 伝搬

branch thread が `FnReturn(value)` を返した場合:
1. 他の全 branch thread を terminate する
2. FnReturn signal を上位に伝搬する

branch thread が `HandleBreak(value)` を返した場合:
1. 他の全 branch thread を terminate する
2. HandleBreak signal を上位に伝搬する

### 7.4 Par と scope chain

par の各 BLOCK thread は同一 agent 内で実行されるため、`VarId` のユニーク性により parent thread の変数を共有 vars マップ経由で読み取れる。ただし par branch 間で変数を書き換えることはない (各 branch は独立した変数を持つ)。

### 7.5 Par 内の request 処理

par branch 内で `IRequest` が実行された場合、通常のツリー遡上ルーティング (第 8 章) で処理される。branch thread → parent thread (A) → さらに上の祖先 の順で handle を検索する。

par の各 branch で生成される child agent は、agent の `children` マップに登録される。

### 7.6 Par のスケジューリング

par branch は同一 agent 内で動作する。ランタイムの実装として:

1. **逐次実行**: 各 branch を順に実行。suspension point に達したら次の branch へ切り替え。全 branch が完了するまで繰り返す。
2. **ラウンドロビン**: suspension point ごとに branch を切り替え。

いずれの実装でも、結果は定義順の配列で返す。branch 間の実行順序は**仕様として定義しない** (ランタイム実装に委ねる)。

## 8. Request ルーティング

### 8.1 概要

request のルーティングは**thread ツリーの遡上**で行われる。request が発生した thread から parent を辿り、各 thread の `handle_scope` を検査する。マッチする handler が見つかればその thread が handle し、root (FN_BODY) まで到達したら親 agent に転送する。

### 8.2 内部 Request (IRequest within agent)

thread T が `IRequest dst rid args` を実行した場合:

```
fn handle_irequest(agent, thread_t_id, dst, rid, args):
    let request = PendingRequest {
        request_id: generate_unique_id(),
        req_def_id: rid,
        args: args.iter().map(|v| agent.vars[v].clone()).collect(),
        from_agent_id: agent.agent_id,
        from_agent_where: agent.self_url,
        dst: dst,
        source_thread: thread_t_id,
    }

    // ツリーを遡上して handler を検索
    route_request(agent, thread_t_id, request)
```

### 8.3 外部 Request (子 agent から受信)

子 agent が `IRequest` を実行し、自身で handle できなかった場合に親 agent (この agent) に転送される:

```
fn on_external_request(agent, request):
    // 子 agent を spawn した thread を特定
    let spawning_thread = agent.children[request.forwarded_by]

    // その thread から遡上して handler を検索
    route_request(agent, spawning_thread, request)
```

`children` マップにより、外部 request のルーティング起点を O(1) で特定できる。

### 8.4 ルーティングアルゴリズム

```
fn route_request(agent, source_thread_id, request):
    let mut current = source_thread_id

    loop:
        let parent = agent.threads[current].parent
        match parent:
            None:
                // Root (FN_BODY) に到達 → 親 agent に転送
                forward_to_parent(agent, request)
                return

            Some(parent_id):
                let parent_thread = &agent.threads[parent_id]
                if let Some(ref scope) = parent_thread.handle_scope:
                    let handle_def = lookup_handle_def(scope.handle_def_id)
                    if let Some(handler_tid) = find_req_case(handle_def, request.req_def_id):
                        // マッチ → この parent thread が handle する
                        handle_request_in_scope(agent, parent_id, handler_tid, request)
                        return

                // マッチしない → さらに上へ
                current = parent_id
```

### 8.5 Request の転送 (親 agent へ)

root thread まで遡上してもマッチする handler がない場合、request を親 agent に転送する:

```
fn forward_to_parent(agent, request):
    // source thread を suspend (reply 待機)
    let source = agent.threads[request.source_thread]
    source.status = Suspended(Request {
        request_id: request.request_id,
        dst: request.dst,
    })

    // 親 agent に POST /agent/request を送信
    send_request(agent.parent_agent_where, RequestMessage {
        request_id: request.request_id,
        req_def_id: request.req_def_id,
        args: request.args,
        from_agent_id: request.from_agent_id,
        from_agent_where: request.from_agent_where,
    })
```

**重要**: 転送時、`from_agent_id` / `from_agent_where` は**元の request 発行元**をそのまま維持する。reply は元の発行元に直接返される。

### 8.6 Reply 受信

親 agent (または handler) から reply が返ってきた場合:

```
fn on_reply(agent, request_id, value):
    // request_id に対応する suspended thread を見つける
    let thread = find_thread_waiting_for_reply(agent, request_id)
    agent.vars[thread.suspend_reason.dst] = value
    thread.status = Running
    // thread の実行を再開
    execute_thread(agent, thread.thread_id)
```

### 8.7 非再入性

agent は**完全に非再入的**である:

- handle の handler 実行中に別の request が到着した場合、その request は handle を管理する thread の `request_queue` に蓄積される
- handler が完了したら、queue から次の request を取り出して処理する
- 同時に実行される handler は常に最大 1 つ

### 8.8 HandlePhase と Request の関係

request がルーティングされ、matching handle を持つ thread H が見つかった場合:

| H の handle_scope.phase | 処理 |
|---|---|
| `RunningBody` | 即座に handler thread を作成して実行。phase を `RunningHandler` に遷移 |
| `RunningHandler` | 非再入のため H の `request_queue` に追加。handler 完了後に処理 |
| `RunningThen` | then 節実行中は handle scope は事実上非アクティブ。request は上位に遡上を継続 |

## 9. available_requests トラッキング

### 9.1 目的

子 agent を `ICall` で生成する際、その時点で handleable な request の一覧を子 agent に送信する必要がある。子 agent はこの情報を基に、自身が発行する request が handle されることを保証する。

### 9.2 計算方法

```
fn compute_available_requests(agent, thread_id) -> HashSet<RequestId>:
    let mut result = HashSet::new()
    let mut current = Some(thread_id)

    while let Some(tid) = current:
        let thread = &agent.threads[tid]
        if let Some(ref scope) = thread.handle_scope:
            let handle_def = lookup_handle_def(scope.handle_def_id)
            for (req_id, _) in handle_def.req_cases:
                result.insert(req_id)
        current = thread.parent

    // 親 agent 経由で handle される request も含む
    result.extend(&agent.parent_available_requests)
    result
```

### 9.3 キャッシュ戦略

`available_requests` は各 thread にキャッシュする:

- **Thread 生成時**: parent の `available_requests` を継承
- **IHandle 実行時**: handle_scope の req_cases を `available_requests` に追加。子孫 thread にも伝搬
- **Handle 完了時**: 追加分を `available_requests` から除去
- **ICall 時**: 現在の thread の `available_requests` を子 agent に送信

キャッシュを維持しない場合は、ICall の度にツリーを遡上して計算しても良い (correctness は同等)。

## 10. 協調イベントループ

### 10.1 Suspension Point

以下の命令が suspension point であり、thread が実行を中断する:

| 命令 | 待機対象 | ThreadStatus |
|------|---------|-------------|
| `IHandle` | child thread (HANDLER_TARGET) | `Suspended(Handle)` |
| `IFor` | child thread (FOR_BODY) の反復 | `Suspended(For)` |
| `IPar` | 全 child thread (BLOCK) の完了 | `Suspended(Par)` |
| `ICall` | child agent の完了 | `Suspended(Call)` |
| `IRequest` | reply (親 agent 転送時のみ) | `Suspended(Request)` |

注意: `IRequest` が agent 内の handler でキャッチされた場合、handler の実行は同期的に行われるため suspension point にはならない。`IRequest` が親 agent に転送された場合のみ thread が suspend する。

### 10.2 Request Queue 処理

handle の handler 実行完了後に request_queue を処理する:

```
fn process_request_queue(agent, thread_id):
    while let Some(request) = agent.threads[thread_id].request_queue.pop_front():
        handle_request_in_scope(agent, thread_id, find_handler_tid(request), request)
        // handler 実行中に新たな request が queue に追加される可能性がある
```

### 10.3 外部イベント受信

agent が外部からイベント (子 agent の完了、reply、外部 request) を受信した場合:

```
fn on_event(agent, event):
    match event:
        ChildCompleted { child_id, value }:
            let thread = find_thread_waiting_for_call(agent, child_id)
            agent.vars[thread.suspend_dst] = value
            thread.status = Running
            agent.children.remove(child_id)
            resume_thread(agent, thread.thread_id)

        ReplyReceived { request_id, value }:
            let thread = find_thread_waiting_for_reply(agent, request_id)
            agent.vars[thread.suspend_dst] = value
            thread.status = Running
            resume_thread(agent, thread.thread_id)

        RequestReceived { request }:
            on_external_request(agent, request)

        TerminateReceived:
            handle_terminate(agent)
```

## 11. プリミティブ操作

### 11.1 算術演算

| 演算 | ルール |
|------|--------|
| `IAdd` | integer + integer = integer, それ以外 = number (f64) |
| `ISub` | integer - integer = integer, それ以外 = number (f64) |
| `IMul` | integer * integer = integer, それ以外 = number (f64) |
| `IDiv` | **常に** number (f64) を返す。整数除算は `prim.div` を使用。 |
| `IMod` | integer % integer = integer, それ以外 = number (f64) |
| `INeg` | integer の場合 integer、number の場合 number |

型の自動昇格 (promotion) ルール: 一方が integer で他方が number の場合、integer を number に昇格して number 演算を行う。

### 11.2 比較演算

| 演算 | ルール |
|------|--------|
| `ICmpEq` / `ICmpNe` | 構造的等価性。型が異なれば不等。array/object は再帰的に比較。 |
| `ICmpLt` / `ICmpLe` / `ICmpGt` / `ICmpGe` | 数値比較。integer/number 間は自動昇格。非数値はランタイムエラー。 |

### 11.3 論理演算

| 演算 | ルール |
|------|--------|
| `IAnd` | boolean && boolean = boolean。非 boolean はランタイムエラー。 |
| `IOr` | boolean \|\| boolean = boolean。非 boolean はランタイムエラー。 |
| `INot` | !boolean = boolean。非 boolean はランタイムエラー。 |

### 11.4 文字列・配列結合

`IConcat dst lhs rhs`:
- `lhs` が String の場合: 文字列結合。`rhs` も String であること。
- `lhs` が Array の場合: 配列結合。`rhs` も Array であること。
- それ以外: ランタイムエラー。

### 11.5 型変換

`ITypeOf dst src`: `src` のランタイム型タグを String で返す。

| 値 | 結果 |
|----|------|
| Null | `"null"` |
| Integer | `"integer"` |
| Number | `"number"` |
| Boolean | `"boolean"` |
| String | `"string"` |
| Array | `"array"` |
| Object | `"object"` |

`IToString dst src`: 値を文字列に変換する。

| 値 | 結果 |
|----|------|
| Null | `"null"` |
| Boolean(true) | `"true"` |
| Boolean(false) | `"false"` |
| Integer(n) | 10 進数文字列 (例: `"42"`, `"-7"`) |
| Number(n) | 10 進数文字列 (例: `"3.14"`, `"-0.5"`) |
| String(s) | `s` (恒等変換) |
| Array(a) | JSON 文字列表現 (例: `"[1,2,3]"`) |
| Object(o) | JSON 文字列表現 (例: `"{\"a\":1}"`) |

### 11.6 Object 操作

- `INewObject dst fields`: `fields` の各 `(constId, varId)` から object を構築。constId は定数プール内の String を指す。
- `IGetField dst obj field`: `obj` から `field` (constId → String) のフィールドを取得。フィールドが存在しない場合はランタイムエラー。
- `ISetField obj dst field val`: `obj` のコピーを作成し、`field` を `val` に更新した新しい object を `dst` に設定。元の `obj` は変更しない (不変)。
- `IHasField dst obj field`: `obj` に `field` が存在すれば `true`、そうでなければ `false`。

### 11.7 Array 操作

- `INewArray dst elems`: 要素リストから配列を構築。
- `IArrGet dst arr idx`: `arr[idx]` を取得。`idx` は Integer。範囲外はランタイムエラー。
- `IArrLen dst arr`: 配列長を Integer で返す。
- `IArrPush dst arr elem`: `arr` の末尾に `elem` を追加した**新しい**配列を返す。元の `arr` は変更しない (不変)。
- `IArrSlice dst arr start end`: `arr[start..end]` のスライスを新しい配列で返す。`start`/`end` は Integer。

## 12. 組み込み Agent / Request

以下の組み込み agent / request は IR に含まれず、ランタイムが直接実装する。`ICall` や `IRequest` で対応する AgentId/RequestId が参照された場合、ランタイムはネイティブ実装を呼び出す。

### 12.1 組み込み Agent

| 修飾名 | 引数 | 戻り値 | 説明 |
|--------|------|--------|------|
| `prim.to_string` | `(v: any)` | `string` | 値を文字列に変換 (IToString と同等) |
| `prim.div` | `(a: integer, b: integer)` | `integer` | 床除算 (floor division) |
| `prim.mod` | `(a: integer, b: integer)` | `integer` | 剰余 |
| `prim.parse_integer` | `(s: string)` | `integer` | 文字列を integer にパース。失敗時は `prim.parse_error` request を発行 |
| `prim.parse_number` | `(s: string)` | `number` | 文字列を number にパース。失敗時は `prim.parse_error` request を発行 |
| `prim.parse_boolean` | `(s: string)` | `boolean` | 文字列を boolean にパース。失敗時は `prim.parse_error` request を発行 |
| `prim.log.info` | `(msg: string)` | `null` | 情報ログ出力 |
| `prim.log.warn` | `(msg: string)` | `null` | 警告ログ出力 |
| `prim.log.error` | `(msg: string)` | `null` | エラーログ出力 |
| `prim.length` | `(arr: array)` | `integer` | 配列長 (IArrLen と同等) |
| `prim.slice` | `(arr: array, start: integer, end: integer)` | `array` | 配列スライス |

### 12.2 組み込み Request

| 修飾名 | 引数 | 戻り値 | 説明 |
|--------|------|--------|------|
| `prim.throw` | `(message: string)` | `never` | エラー request。全 agent に暗黙的に `with throw` が含まれる |
| `prim.parse_error` | `(message: string)` | `never` | パース失敗 request |

### 12.3 throw のデフォルトハンドラ

ランタイムはトップレベル agent (root) に暗黙的な `throw` handler を提供する:

- `throw` request が root agent まで伝搬した場合、ランタイムのデフォルトハンドラがエラーメッセージとスタックトレースを出力して agent を terminate する
- ユーザーコードで `throw` の handler を定義した場合、そのスコープ内ではデフォルトハンドラがシャドウされる

スタックトレースはランタイムが agent の呼び出し階層を自動追跡して生成する。

## 13. Terminate 伝搬

### 13.1 Terminate 受信時の処理

agent が terminate を受信した場合:

```
fn handle_terminate(agent):
    // 1. 全子 agent に再帰的に terminate を送信
    for child_id in agent.children.keys():
        send_terminate(child_id)

    // 2. 全子 agent の terminate_ack を待機
    wait_for_all_terminate_acks(agent)

    // 3. 親 agent に terminate_ack を送信
    send_terminate_ack(agent.parent_agent_where, agent.agent_id)

    // 4. 全 thread を Completed に遷移
    for thread in agent.threads.values_mut():
        thread.status = Completed(Signal::Normal(Value::Null))
```

### 13.2 Terminate が発生するケース

| トリガー | 対象 | 説明 |
|---------|------|------|
| `IHandleBreak` | handle scope 内の全 child agent | handler が `break` で handle scope を脱出 |
| `IReturn` の巻き上げ | 巻き上げ途中の全 scope 内の child agent | `return` 文による FN_BODY までの unwind |
| par branch の signal 伝搬 | 他の par branch 内の child agent | FnReturn / HandleBreak が par branch を通過する際 |
| 親からの terminate | 全 child agent | 親 agent が terminate された場合の再帰伝搬 |

### 13.3 Thread のクリーンアップ

thread が terminate される場合 (FnReturn の巻き上げ、HandleBreak、par signal など):

```
fn terminate_thread(agent, thread_id):
    let thread = &agent.threads[thread_id]

    // child thread を再帰的に terminate
    // (handle_scope の body/handler, for の body, par の branches)
    for child_tid in get_child_threads(agent, thread_id):
        terminate_thread(agent, child_tid)

    // この thread から spawn された child agent に terminate を送信
    for (child_agent_id, spawning_tid) in agent.children:
        if spawning_tid == thread_id:
            send_terminate(child_agent_id)

    // thread を除去
    agent.threads.remove(thread_id)
```

### 13.4 正常完了時

agent の root thread が正常に完了した場合 (`FN_BODY` の `IComplete` に到達)、全ての suspension point は同期的に child の完了を待機した後に次命令に進むため、この時点で生存中の child agent や child thread は存在しない。terminate の送信は不要。

## 14. 永続化モデル

### 14.1 Persistence Boundary

suspension point (`ICall`, `IPar`, `IRequest` の親 agent 転送時) は自然な永続化境界 (persistence boundary) である。これらの地点で agent の状態をシリアライズし、永続ストレージに保存できる。

### 14.2 シリアライズ対象

`AgentState` 全体が永続化対象。thread ツリーはフラットな HashMap + parent 参照として保存する:

```json
{
    "agent_id": "agent-001",
    "agent_def_id": 0,
    "parent_agent_id": "agent-000",
    "parent_agent_where": "https://runtime.example.com/agents/agent-000",
    "root_thread": 0,
    "threads": {
        "0": {
            "thread_id": 0,
            "kind": "FN_BODY",
            "pc": 5,
            "status": { "Suspended": { "Handle": { "handle_def_id": 0, "dst": 10 } } },
            "parent": null,
            "handle_scope": {
                "handle_def_id": 0,
                "dst": 10,
                "phase": { "RunningBody": { "body_thread": 1 } }
            },
            "request_queue": [],
            "available_requests": [0, 1]
        },
        "1": {
            "thread_id": 1,
            "kind": "HANDLER_TARGET",
            "pc": 3,
            "status": { "Suspended": { "Call": { "child_agent_id": "agent-002", "dst": 5 } } },
            "parent": 0,
            "handle_scope": null,
            "request_queue": [],
            "available_requests": [0, 1]
        }
    },
    "vars": { "0": null, "1": 42, "2": "hello", "5": null, "10": null },
    "handle_states": {
        "0": { "state_vars": { "3": 0 } }
    },
    "children": { "agent-002": 1 },
    "parent_available_requests": [2, 3]
}
```

### 14.3 復元と再開

永続化された AgentState をストレージから読み込み、以下の手順で実行を再開する:

1. AgentState をデシリアライズする
2. thread ツリーを再構築する (parent 参照から)
3. 各 thread の `status` に応じて待機状態を再構築する:
   - `Suspended(Call)`: child agent の完了イベントを待機
   - `Suspended(Par)`: 全 branch thread の完了イベントを待機
   - `Suspended(Request)`: reply イベントを待機
   - `Suspended(Handle/For)`: child thread を再開
4. イベントが到着したら、通常の実行ループに戻る

### 14.4 Value のシリアライズ

全ての Value は JSON 互換であるため、直接 JSON としてシリアライズ可能。Integer は JSON の number に収まらない場合は string として保存し、型タグを付与する。

```json
{"type": "integer", "value": "99999999999999999999"}
{"type": "number", "value": 3.14}
{"type": "null"}
{"type": "boolean", "value": true}
{"type": "string", "value": "hello"}
{"type": "array", "value": [...]}
{"type": "object", "value": {...}}
```
