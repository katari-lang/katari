# ランタイムサーバー実装

spec 参照: `07-katari-protocol.md`, `08-ir.md`, `10-servers.md`

---

## モジュール構成と依存関係

```
main
  ├── ir_loader      IR バイナリ読み込み・デコード
  ├── agent_manager  Agent の生成・管理・状態永続化
  ├── interpreter    フラット命令列インタープリタ
  ├── request_router 親ベースルーティング・プロキシモード
  ├── protocol       Katari Protocol REST エンドポイント
  └── schema         JSON Schema 生成 (GET /task, /request レスポンス用)
```

---

## 1. ir_loader

**役割**: IR バイナリ (`"KTRI"` フォーマット) をデコードし、実行可能な構造に変換

**主要データ型**:
```rust
struct Program {
    modules: Vec<Module>,
}

struct Module {
    name: ModuleName,
    name_table: NameTable,
    constants: Vec<Constant>,
    request_defs: Vec<RequestDef>,
    tasks: Vec<Task>,
}

struct Task {
    task_id: TaskId,
    params: Vec<VarId>,
    body: Vec<Instruction>,
    handle_blocks: Vec<HandleBlock>,
}

struct HandleBlock {
    handler_id: HandlerId,
    state_params: Vec<(VarId, InitExpr)>,
    request_handlers: Vec<(RequestId, Vec<Instruction>)>,
    return_handler: Option<Vec<Instruction>>,
}

enum Instruction {
    // 定数・移動
    ILoadConst(VarId, ConstId),
    ILoadNull(VarId),
    IMove(VarId, VarId),
    // Object
    INewObject(VarId, Vec<(ConstId, VarId)>),
    IGetField(VarId, VarId, ConstId),
    ISetField(VarId, VarId, ConstId, VarId),
    IHasField(VarId, VarId, ConstId),
    // Array
    INewArray(VarId, Vec<VarId>),
    IArrGet(VarId, VarId, VarId),
    IArrLen(VarId, VarId),
    IArrPush(VarId, VarId, VarId),
    IArrConcat(VarId, VarId, VarId),
    IArrSlice(VarId, VarId, VarId, VarId),
    // 整数演算
    IAddInt(VarId, VarId, VarId),
    ISubInt(VarId, VarId, VarId),
    IMulInt(VarId, VarId, VarId),
    IModInt(VarId, VarId, VarId),
    INegInt(VarId, VarId),
    // 浮動小数演算
    IAddFlt(VarId, VarId, VarId),
    ISubFlt(VarId, VarId, VarId),
    IMulFlt(VarId, VarId, VarId),
    IDivFlt(VarId, VarId, VarId),
    INegFlt(VarId, VarId),
    // 除算 (常に float)
    IDiv(VarId, VarId, VarId),
    // 比較
    ICmpEq(VarId, VarId, VarId),
    ICmpNe(VarId, VarId, VarId),
    ICmpLt(VarId, VarId, VarId),
    ICmpLe(VarId, VarId, VarId),
    ICmpGt(VarId, VarId, VarId),
    ICmpGe(VarId, VarId, VarId),
    // 論理
    IAnd(VarId, VarId, VarId),
    IOr(VarId, VarId, VarId),
    INot(VarId, VarId),
    // 文字列
    IStrConcat(VarId, VarId, VarId),
    // 型変換
    IToString(VarId, VarId),
    IIntToFlt(VarId, VarId),
    ITypeOf(VarId, VarId),
    // 制御フロー
    IJump(u32),
    IBranch(VarId, u32, u32),
    ISwitch(VarId, Vec<(ConstId, u32)>, u32),
    IReturn(VarId),
    // Agent 操作 (yield 点)
    ICall(VarId, TaskId, Vec<VarId>),
    IPar(VarId, Vec<(TaskId, Vec<VarId>)>),
    IRequest(VarId, RequestId, Vec<VarId>),
    // Handle ライフサイクル
    IHandleBegin(HandlerId),
    IHandleEnd(HandlerId),
    // Handler 内命令
    IReply(VarId, HandlerId, Vec<(u32, VarId)>),
    IBreak(VarId, HandlerId),
    // For ループ内命令
    INext(Vec<(u32, VarId)>),
    IForBreak(VarId),
}

enum Constant {
    Int(i128),
    Float(f64),
    String(String),
    Bool(bool),
    Null,
}
```

---

## 2. agent_manager

**役割**: Agent の生成・状態管理・永続化

**主要データ型**:
```rust
struct AgentState {
    agent_id: AgentId,
    parent_agent_id: AgentId,
    parent_agent_where: Url,
    task_id: TaskId,
    instruction_pointer: u32,
    vars: HashMap<VarId, Value>,
    handler_states: HashMap<HandlerId, HashMap<VarId, Value>>,
    active_handlers: Vec<HandlerId>,
    request_queue: VecDeque<PendingRequest>,
    children: HashSet<AgentId>,
    status: AgentStatus,
}

enum AgentStatus {
    Running,
    WaitingCall(AgentId),
    WaitingPar(Vec<AgentId>),
    WaitingReply(RequestId),
    Terminated,
}

struct PendingRequest {
    request_id: RequestId,
    request_name: String,
    args: Vec<Value>,
    from_agent_id: AgentId,
    from_agent_where: Url,
}

// ランタイム値 (JSON 互換)
enum Value {
    Null,
    Integer(i128),
    Number(f64),
    Boolean(bool),
    String(String),
    Array(Vec<Value>),
    Object(HashMap<String, Value>),
}
```

**主要関数**:
```rust
fn spawn_agent(task_id, args, parent_agent_id, parent_agent_where, with_effects) -> AgentId
fn get_agent_state(agent_id) -> Option<AgentState>
fn update_agent_status(agent_id, status)
fn enqueue_request(agent_id, request)
fn persist_agent_state(agent_id)     // yield 点でスナップショット保存 (PostgreSQL 等)
fn restore_agent_state(agent_id)     // サーバー再起動後の状態復元
```

---

## 3. interpreter

**役割**: AgentState を持つコルーチンとして命令列を実行する協調イベントループ

**実行ループ**:
```
loop {
    instruction = body[agent.instruction_pointer]
    match instruction {
        // 通常命令: 実行して IP をインクリメント
        ILoadConst, IMove, IAddInt, ... => {
            execute(instruction, &mut agent.vars)
            agent.instruction_pointer += 1
        }

        // yield 点: キューをチェックしてから実際の待機へ
        ICall(dst, task_id, args) => {
            check_and_process_queue(&mut agent)   // pending request を 1 件処理
            child_id = spawn_child(task_id, args, agent.agent_id)
            agent.status = WaitingCall(child_id)
            yield  // runtime イベントループに制御を返す
        }

        IPar(dst, tasks) => {
            check_and_process_queue(&mut agent)
            children = tasks.iter().map(|(tid, args)| spawn_child(tid, args, agent.agent_id)).collect()
            agent.status = WaitingPar(children)
            yield
        }

        IRequest(dst, request_id, args) => {
            check_and_process_queue(&mut agent)
            forward_request(agent.parent_agent_where, request_id, args, agent.agent_id)
            agent.status = WaitingReply(request_id)
            yield
        }

        IHandleBegin(handler_id) => {
            // handler_id を active_handlers スタックに追加
            // StateParams の InitExpr を評価して handler_states[handler_id] を初期化
            agent.active_handlers.push(handler_id)
        }

        IHandleEnd(handler_id) => {
            agent.active_handlers.retain(|h| h != handler_id)
        }

        IReturn(val) => {
            result = agent.vars[val]
            notify_parent_return(agent.parent_agent_where, result)
            agent.status = Terminated
            yield
        }
    }
}

// request キューの処理 (1 件)
fn check_and_process_queue(agent) {
    if let Some(req) = agent.request_queue.pop_front() {
        // active_handlers を内側 (末尾) から検索
        if let Some(handler) = find_handler(agent.active_handlers, req.request_id) {
            execute_handler(agent, handler, req)
        } else {
            // プロキシモード: 親へ転送
            forward_to_parent(agent, req)
            // WaitingReply 状態 → 転送完了まで queue check しない
        }
    }
}

fn execute_handler(agent, handler_id, req) {
    let state_vars = agent.handler_states[handler_id].clone()
    let args = [req.args, state_vars].concat()
    execute_handler_instructions(handler.instructions, args) → outcome

    match outcome {
        IReply(val, hid, updates) => {
            // state 更新
            for (var_idx, new_val) in updates {
                agent.handler_states[hid][var_idx] = new_val
            }
            // reply を返送
            send_reply(req.from_agent_where, req.request_id, val)
        }
        IBreak(val, hid) => {
            // hid のスコープ内の全直接子に terminate 送信
            terminate_scope_children(agent, hid)
            // break 値を handle expression の結果として設定
            complete_handle_scope(agent, hid, val)
        }
    }
}
```

---

## 4. request_router

**役割**: 子からの request を適切なハンドラに届ける。handler がなければ親へ転送

**転送フロー (プロキシモード)**:
```
1. 子からの POST /agent/request を受信
2. agent の active_handlers を内側から検索
3. 対応する handler が存在する → execute_handler() で処理し reply 返送
4. 存在しない →
   a. agent を WaitingReply 状態にする (全 request がキューで待機)
   b. agent.parent_agent_where に POST /agent/request を転送
   c. 親から POST /agent/reply が届いたら元の from_agent_where に転送
   d. agent を Running に戻す
```

**terminate 伝播**:
```
1. 親から POST /agent/terminate を受信
2. agent が直接の子に POST /agent/terminate を再帰送信
3. 全子から POST /agent/terminate_ack が返ったら
4. 親に POST /agent/terminate_ack を送信
5. agent.status = Terminated
```

---

## 5. protocol (Katari Protocol エンドポイント)

**役割**: Katari Protocol の REST API 実装 (axum)

**エンドポイント一覧**:

```
GET  /task                   利用可能な task 定義一覧 (JSON Schema 付き)
GET  /request                利用可能な request 定義一覧 (JSON Schema 付き)
GET  /agent                  全 agent 一覧
GET  /agent/:agent_id        agent 詳細情報

POST /agent                  agent 生成・実行開始
  body: { task_id, args, parent_agent_id, parent_agent_where, with_effects }
  response: { agent_id, agent_where }

POST /agent/request          子 agent からの request 受け取り
  body: { request_id, request_name, args, from_agent_id, from_agent_where }
  response: { success: true }

POST /agent/reply            parent から子 agent への reply
  body: { request_id, result, from_agent_id, from_agent_where, agent_id }
  response: { success: true }

POST /agent/terminate        parent から子 agent への停止指示
  body: { agent_id, from_agent_id, from_agent_where }
  response: { success: true }

POST /agent/return           子 agent の正常完了通知
  body: { result, from_agent_id, from_agent_where, agent_id }
  response: { success: true }

POST /agent/terminate_ack    子 agent の停止確認通知
  body: { from_agent_id, from_agent_where, agent_id }
  response: { success: true }

--- Runtime 固有エンドポイント ---
POST /apply                  IR バイナリのデプロイ
  body: binary (.ktri)

POST /run                    外部からの task 実行
  body: { task_id, args }
  response: { run_id }

GET  /run/:run_id            実行結果取得
  response: { status: running | completed | failed, result? }

GET  /run                    実行中の run 一覧
```

---

## 6. 実行モデルまとめ

```
POST /agent 受信
  → spawn_agent() で AgentState 生成
  → interpreter をタスクとして起動 (tokio::spawn)
  → 即座に { agent_id, agent_where } を返す

インタープリタが実行
  → yield 点 (ICall/IPar/IRequest) で:
      1. キューを確認・処理 (1 件)
      2. 待機状態に遷移
  → 外部イベント (reply/return/terminate_ack) で再開
  → IReturn で POST /agent/return を親へ送信

POST /agent/request 受信
  → agent の request_queue に追加
  → agent が suspension point にあれば即座に check_and_process_queue()

永続化:
  → yield 点で AgentState を JSON シリアライズして DB 保存
  → サーバー再起動時に DB から復元して実行継続
```
