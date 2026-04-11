use std::collections::HashMap;

use katari_runtime::ir::instruction::Instruction;
use katari_runtime::ir::*;
use katari_runtime::runtime::Runtime;
use katari_runtime::value::Value;

fn empty_module() -> IRModule {
    IRModule {
        name: "test".into(),
        name_table: NameTable::default(),
        consts: vec![],
        requests: vec![],
        threads: vec![],
        handles: vec![],
        fors: vec![],
        agents: vec![],
    }
}

/// Helper: run an agent and return its result value.
fn run_and_get(module: IRModule, agent_name: &str, args: Vec<Value>) -> Value {
    let mut name_map = HashMap::new();
    for a in &module.agents {
        name_map.insert(a.name.clone(), a.id);
    }
    let mut rt = Runtime::new("http://test".into());
    rt.apply_module(module, name_map, HashMap::new());
    let agent_id = rt.run_agent(agent_name, args).expect("run_agent failed");
    rt.get_agent_result(&agent_id)
}

// =========================================================================
// Test 1: Simple arithmetic  (1 + 2 = 3)
// =========================================================================
#[test]
fn test_simple_add() {
    let mut m = empty_module();
    // consts: 0=Int(1), 1=Int(2)
    m.consts = vec![ConstVal::Int(1), ConstVal::Int(2)];
    // thread 0: LoadConst v0 c0; LoadConst v1 c1; Add v2 v0 v1; Complete v2
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(0, 0),
            Instruction::LoadConst(1, 1),
            Instruction::Add(2, 0, 1),
            Instruction::Complete(2),
        ],
    }];
    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.add".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.add", vec![]);
    assert_eq!(result, Value::Integer(3));
}

// =========================================================================
// Test 2: Agent with parameters
// =========================================================================
#[test]
fn test_agent_with_params() {
    let mut m = empty_module();
    // thread 0: params=[v0, v1], body: Add v2 v0 v1; Complete v2
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![0, 1],
        body: vec![Instruction::Add(2, 0, 1), Instruction::Complete(2)],
    }];
    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.add_params".into(),
        entry: 0,
    }];

    let result = run_and_get(
        m,
        "test.add_params",
        vec![Value::Integer(10), Value::Integer(20)],
    );
    assert_eq!(result, Value::Integer(30));
}

// =========================================================================
// Test 3: Branch (if/else)
// =========================================================================
#[test]
fn test_branch_true() {
    let mut m = empty_module();
    m.consts = vec![ConstVal::Int(42), ConstVal::Int(99)];
    // param v0 = condition
    // branch v0 → pc=2 (true), pc=4 (false)
    // pc=2: LoadConst v1 c0 (42); Complete v1
    // pc=4: LoadConst v1 c1 (99); Complete v1
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![0],
        body: vec![
            /* 0 */ Instruction::Branch(0, 2, 4),
            /* 1 - unreachable */ Instruction::LoadNull(1),
            /* 2 */ Instruction::LoadConst(1, 0), // 42
            /* 3 */ Instruction::Complete(1),
            /* 4 */ Instruction::LoadConst(1, 1), // 99
            /* 5 */ Instruction::Complete(1),
        ],
    }];
    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.branch".into(),
        entry: 0,
    }];

    // true branch
    let result = run_and_get(m.clone(), "test.branch", vec![Value::Boolean(true)]);
    assert_eq!(result, Value::Integer(42));

    // false branch
    let result = run_and_get(m, "test.branch", vec![Value::Boolean(false)]);
    assert_eq!(result, Value::Integer(99));
}

// =========================================================================
// Test 4: Object creation and field access
// =========================================================================
#[test]
fn test_object_operations() {
    let mut m = empty_module();
    // consts: 0=Str("x"), 1=Int(10), 2=Str("y"), 3=Int(20)
    m.consts = vec![
        ConstVal::Str("x".into()),
        ConstVal::Int(10),
        ConstVal::Str("y".into()),
        ConstVal::Int(20),
    ];
    // v0=10, v1=20, v2={x:v0, y:v1}, v3=v2.x, Complete v3
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(0, 1),         // v0 = 10
            Instruction::LoadConst(1, 3),         // v1 = 20
            Instruction::NewObject(2, vec![(0, 0), (2, 1)]), // v2 = {x: 10, y: 20}
            Instruction::GetField(3, 2, 0),       // v3 = v2.x = 10
            Instruction::Complete(3),
        ],
    }];
    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.obj".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.obj", vec![]);
    assert_eq!(result, Value::Integer(10));
}

// =========================================================================
// Test 5: Primitive agent call (prim.to_string)
// =========================================================================
#[test]
fn test_prim_to_string() {
    let mut m = empty_module();
    m.consts = vec![ConstVal::Int(42)];
    // Agent 0 = prim.to_string (primitive)
    // Agent 1 = test.main (calls prim.to_string)
    m.agents = vec![
        IRAgentDef { id: 0, name: "prim.to_string".into(), entry: 100 },
        IRAgentDef { id: 1, name: "test.main".into(), entry: 0 },
    ];
    // thread 0 (FnBody for test.main):
    //   LoadConst v0 c0 (42)
    //   Call v1, agent=0, args=[v0]   ← calls prim.to_string
    //   Complete v1
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(0, 0),
            Instruction::Call(1, 0, vec![0]),
            Instruction::Complete(1),
        ],
    }];

    let result = run_and_get(m, "test.main", vec![]);
    assert_eq!(result, Value::String("42".into()));
}

// =========================================================================
// Test 6: For loop (sum of array)
// =========================================================================
#[test]
fn test_for_loop_sum() {
    let mut m = empty_module();
    // We want to sum [1, 2, 3]
    // consts: 0=Int(1), 1=Int(2), 2=Int(3), 3=Int(0)
    m.consts = vec![
        ConstVal::Int(1),
        ConstVal::Int(2),
        ConstVal::Int(3),
        ConstVal::Int(0),
    ];

    // Main thread (id=0, FnBody):
    //   v0 = [1, 2, 3]
    //   v1 = 0  (initial acc)
    //   For v10, for_def=0
    //   Complete v10
    m.threads.push(IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(100, 0),  // 1
            Instruction::LoadConst(101, 1),  // 2
            Instruction::LoadConst(102, 2),  // 3
            Instruction::NewArray(0, vec![100, 101, 102]),  // v0 = [1,2,3]
            Instruction::LoadConst(1, 3),    // v1 = 0 (initial acc)
            Instruction::For(10, 0),         // for(v10, for_def_0)
            Instruction::Complete(10),
        ],
    });

    // For body thread (id=1, ForBody):
    //   params: none (iter_var=v2 is set by for_loop)
    //   body: acc(v3) = acc(v3) + elem(v2); ForContinue([(v3, v4)])
    //   where v3 is the state var, v4 is the new value
    //   Actually: Add v4 v3 v2; ForContinue([(v3, v4)])
    m.threads.push(IRThread {
        id: 1,
        kind: ThreadKind::ForBody,
        params: vec![],
        body: vec![
            Instruction::Add(4, 3, 2),           // v4 = acc + elem
            Instruction::ForContinue(vec![(3, 4)]), // update acc (v3 = v4)
        ],
    });

    // For then thread (id=2, ForThen):
    //   params: none
    //   body: Complete v3  (return the accumulated value)
    m.threads.push(IRThread {
        id: 2,
        kind: ThreadKind::ForThen,
        params: vec![],
        body: vec![Instruction::Complete(3)],
    });

    // For def:
    //   iter_vars: [v2] (element variable)
    //   arrays: [v0] (the array)
    //   state_vars: [v3] (accumulator)
    //   state_inits: [v1] (initial value = 0)
    //   body: thread 1
    //   then: Some(thread 2)
    m.fors = vec![IRForDef {
        id: 0,
        iter_vars: vec![2],
        arrays: vec![0],
        state_vars: vec![3],
        state_inits: vec![1],
        body: 1,
        then: Some(2),
    }];

    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.sum".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.sum", vec![]);
    assert_eq!(result, Value::Integer(6)); // 1 + 2 + 3 = 6
}

// =========================================================================
// Test 7: Handle with internal request
// =========================================================================
#[test]
fn test_handle_with_request() {
    let mut m = empty_module();
    // Scenario:
    //   handle (state: count = 0) {
    //     body: request "inc" → result; return result
    //   } case inc() {
    //     continue count + 1 with { count = count + 1 }
    //   } then(body_result) {
    //     return count
    //   }
    //
    // But simpler:
    //   Main agent does IHandle, body does IRequest, handler does IContinue,
    //   then returns the state var.

    m.consts = vec![
        ConstVal::Int(0),  // c0 = 0 (initial state)
        ConstVal::Int(1),  // c1 = 1
    ];

    // Request def: id=0
    m.requests = vec![IRRequestDef {
        id: 0,
        name: "inc".into(),
        from: None,
    }];

    // Thread 0 (FnBody, main agent entry):
    //   v10 = 0 (state init)
    //   Handle v20, handle_def=0
    //   Complete v20
    m.threads.push(IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(10, 0),  // v10 = 0
            Instruction::Handle(20, 0),
            Instruction::Complete(20),
        ],
    });

    // Thread 1 (HandlerTarget - handle body):
    //   Request v30, request_def=0, args=[]
    //   Complete v30
    m.threads.push(IRThread {
        id: 1,
        kind: ThreadKind::HandlerTarget,
        params: vec![],
        body: vec![
            Instruction::Request(30, 0, vec![]),
            Instruction::Complete(30),
        ],
    });

    // Thread 2 (RequestHandler - handler for request 0):
    //   params: [] (no request args)
    //   body:
    //     Add v40, v11, c1  → v40 = count + 1
    //     Continue v40, [(v11, v40)]  → reply with count+1, update count
    m.threads.push(IRThread {
        id: 2,
        kind: ThreadKind::RequestHandler,
        params: vec![],
        body: vec![
            Instruction::LoadConst(41, 1),        // v41 = 1
            Instruction::Add(40, 11, 41),         // v40 = v11(count) + 1
            Instruction::Continue(40, vec![(11, 40)]),
        ],
    });

    // Thread 3 (HandleThen):
    //   params: [v50] (body result)
    //   body: Complete v50  (return body result, which is the reply value)
    m.threads.push(IRThread {
        id: 3,
        kind: ThreadKind::HandleThen,
        params: vec![50],
        body: vec![Instruction::Complete(50)],
    });

    // Handle def:
    //   state_vars: [v11]
    //   state_inits: [v10]  (= 0)
    //   body: thread 1
    //   req_cases: [(request 0, thread 2)]
    //   then: Some(thread 3)
    m.handles = vec![IRHandleDef {
        id: 0,
        state_vars: vec![11],
        state_inits: vec![10],
        body: 1,
        req_cases: vec![(0, 2)],
        then: Some(3),
    }];

    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.handle".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.handle", vec![]);
    // Body does request → handler replies with 0+1=1 → body gets 1 → body completes with 1
    // Then clause gets body_result=1 → completes with 1
    assert_eq!(result, Value::Integer(1));
}

// =========================================================================
// Test 8: Par (parallel branches)
// =========================================================================
#[test]
fn test_par() {
    let mut m = empty_module();
    m.consts = vec![ConstVal::Int(10), ConstVal::Int(20)];

    // Thread 0 (FnBody):
    //   Par v5, [thread1, thread2]
    //   Complete v5    ← v5 will be [10, 20]
    m.threads.push(IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::Par(5, vec![1, 2]),
            Instruction::Complete(5),
        ],
    });

    // Thread 1 (Block): LoadConst v0 c0; Complete v0
    m.threads.push(IRThread {
        id: 1,
        kind: ThreadKind::Block,
        params: vec![],
        body: vec![
            Instruction::LoadConst(0, 0),  // 10
            Instruction::Complete(0),
        ],
    });

    // Thread 2 (Block): LoadConst v1 c1; Complete v1
    m.threads.push(IRThread {
        id: 2,
        kind: ThreadKind::Block,
        params: vec![],
        body: vec![
            Instruction::LoadConst(1, 1),  // 20
            Instruction::Complete(1),
        ],
    });

    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.par".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.par", vec![]);
    assert_eq!(result, Value::Array(vec![Value::Integer(10), Value::Integer(20)]));
}

// =========================================================================
// Test 9: Local agent call (non-primitive ICall)
// =========================================================================
#[test]
fn test_local_agent_call() {
    let mut m = empty_module();
    m.consts = vec![ConstVal::Int(5), ConstVal::Int(3)];

    // Agent 0: "test.double" — takes v0, returns v0 + v0
    // Thread 10 (FnBody for test.double):
    m.threads.push(IRThread {
        id: 10,
        kind: ThreadKind::FnBody,
        params: vec![0],
        body: vec![
            Instruction::Add(1, 0, 0),
            Instruction::Complete(1),
        ],
    });

    // Agent 1: "test.main" — calls test.double(5), returns result + 3
    // Thread 0 (FnBody for test.main):
    m.threads.push(IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(100, 0),       // v100 = 5
            Instruction::Call(101, 0, vec![100]),  // v101 = test.double(5)
            Instruction::LoadConst(102, 1),        // v102 = 3
            Instruction::Add(103, 101, 102),       // v103 = 10 + 3
            Instruction::Complete(103),
        ],
    });

    m.agents = vec![
        IRAgentDef { id: 0, name: "test.double".into(), entry: 10 },
        IRAgentDef { id: 1, name: "test.main".into(), entry: 0 },
    ];

    let result = run_and_get(m, "test.main", vec![]);
    assert_eq!(result, Value::Integer(13)); // double(5) = 10, 10 + 3 = 13
}

// =========================================================================
// Test 10: String concat + ToString
// =========================================================================
#[test]
fn test_string_operations() {
    let mut m = empty_module();
    m.consts = vec![
        ConstVal::Str("hello ".into()),  // c0
        ConstVal::Str("world".into()),   // c1
    ];
    m.threads = vec![IRThread {
        id: 0,
        kind: ThreadKind::FnBody,
        params: vec![],
        body: vec![
            Instruction::LoadConst(0, 0),   // "hello "
            Instruction::LoadConst(1, 1),   // "world"
            Instruction::Concat(2, 0, 1),   // "hello world"
            Instruction::Complete(2),
        ],
    }];
    m.agents = vec![IRAgentDef {
        id: 0,
        name: "test.str".into(),
        entry: 0,
    }];

    let result = run_and_get(m, "test.str", vec![]);
    assert_eq!(result, Value::String("hello world".into()));
}
