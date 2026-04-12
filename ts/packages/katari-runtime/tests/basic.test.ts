import { describe, it, expect } from "vitest";
import type { IRModule, IRThread, IRAgentDef, IRRequestDef, IRHandleDef, IRForDef, ConstVal, Instruction } from "../src/ir.js";
import type { Value } from "../src/value.js";
import { Runtime } from "../src/runtime/index.js";

// ===========================================================================
// Helpers
// ===========================================================================

function emptyModule(): IRModule {
  return {
    name: "test",
    nameTable: new Map(),
    consts: [],
    requests: [],
    threads: [],
    handles: [],
    fors: [],
    agents: [],
  };
}

function runAndGet(module: IRModule, agentName: string, args: Value[]): Value {
  const nameMap = new Map<string, number>();
  for (const a of module.agents) {
    nameMap.set(a.name, a.id);
  }
  const rt = new Runtime("http://test");
  rt.applyModule(module, nameMap, new Map());
  const agentId = rt.runAgent(agentName, args);
  const status = rt.getAgentStatus(agentId);
  return status?.result ?? null;
}

// ===========================================================================
// Tests
// ===========================================================================

describe("Runtime basic tests", () => {
  // Test 1: Simple arithmetic (1 + 2 = 3)
  it("simple add", () => {
    const m = emptyModule();
    m.consts = [{ tag: "Int", value: 1 }, { tag: "Int", value: 2 }];
    m.threads = [{
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 0, cid: 0 },
        { op: "LoadConst", dst: 1, cid: 1 },
        { op: "Add", dst: 2, lhs: 0, rhs: 1 },
        { op: "Complete", val: 2 },
      ],
    }];
    m.agents = [{ id: 0, name: "test.add", entry: 0 }];

    expect(runAndGet(m, "test.add", [])).toBe(3);
  });

  // Test 2: Agent with parameters
  it("agent with params", () => {
    const m = emptyModule();
    m.threads = [{
      id: 0, kind: "FnBody", params: [0, 1],
      body: [
        { op: "Add", dst: 2, lhs: 0, rhs: 1 },
        { op: "Complete", val: 2 },
      ],
    }];
    m.agents = [{ id: 0, name: "test.add_params", entry: 0 }];

    expect(runAndGet(m, "test.add_params", [10, 20])).toBe(30);
  });

  // Test 3: Branch (if/else)
  it("branch true", () => {
    const m = emptyModule();
    m.consts = [{ tag: "Int", value: 42 }, { tag: "Int", value: 99 }];
    m.threads = [{
      id: 0, kind: "FnBody", params: [0],
      body: [
        /* 0 */ { op: "Branch", cond: 0, thenPc: 2, elsePc: 4 } as Instruction,
        /* 1 */ { op: "LoadNull", dst: 1 } as Instruction,
        /* 2 */ { op: "LoadConst", dst: 1, cid: 0 } as Instruction,
        /* 3 */ { op: "Complete", val: 1 } as Instruction,
        /* 4 */ { op: "LoadConst", dst: 1, cid: 1 } as Instruction,
        /* 5 */ { op: "Complete", val: 1 } as Instruction,
      ],
    }];
    m.agents = [{ id: 0, name: "test.branch", entry: 0 }];

    expect(runAndGet(m, "test.branch", [true])).toBe(42);
    expect(runAndGet(m, "test.branch", [false])).toBe(99);
  });

  // Test 4: Object creation and field access
  it("object operations", () => {
    const m = emptyModule();
    m.consts = [
      { tag: "Str", value: "x" },
      { tag: "Int", value: 10 },
      { tag: "Str", value: "y" },
      { tag: "Int", value: 20 },
    ];
    m.threads = [{
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 0, cid: 1 },            // v0 = 10
        { op: "LoadConst", dst: 1, cid: 3 },            // v1 = 20
        { op: "NewObject", dst: 2, fields: [[0, 0], [2, 1]] }, // {x:10, y:20}
        { op: "GetField", dst: 3, obj: 2, field: 0 },   // v3 = v2.x = 10
        { op: "Complete", val: 3 },
      ],
    }];
    m.agents = [{ id: 0, name: "test.obj", entry: 0 }];

    expect(runAndGet(m, "test.obj", [])).toBe(10);
  });

  // Test 5: Primitive agent call (prim.to_string)
  it("prim to_string", () => {
    const m = emptyModule();
    m.consts = [{ tag: "Int", value: 42 }];
    m.agents = [
      { id: 0, name: "prim.to_string", entry: 100 },
      { id: 1, name: "test.main", entry: 0 },
    ];
    m.threads = [{
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 0, cid: 0 },
        { op: "Call", dst: 1, agentDefId: 0, args: [0] },
        { op: "Complete", val: 1 },
      ],
    }];

    expect(runAndGet(m, "test.main", [])).toBe("42");
  });

  // Test 6: For loop (sum of array)
  it("for loop sum", () => {
    const m = emptyModule();
    m.consts = [
      { tag: "Int", value: 1 },
      { tag: "Int", value: 2 },
      { tag: "Int", value: 3 },
      { tag: "Int", value: 0 },
    ];

    // Main thread
    m.threads.push({
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 100, cid: 0 },
        { op: "LoadConst", dst: 101, cid: 1 },
        { op: "LoadConst", dst: 102, cid: 2 },
        { op: "NewArray", dst: 0, elems: [100, 101, 102] },
        { op: "LoadConst", dst: 1, cid: 3 },   // v1 = 0 (initial acc)
        { op: "For", dst: 10, forId: 0 },
        { op: "Complete", val: 10 },
      ],
    });

    // For body
    m.threads.push({
      id: 1, kind: "ForBody", params: [],
      body: [
        { op: "Add", dst: 4, lhs: 3, rhs: 2 },
        { op: "ForContinue", mutations: [[3, 4]] },
      ],
    });

    // For then
    m.threads.push({
      id: 2, kind: "ForThen", params: [],
      body: [
        { op: "Complete", val: 3 },
      ],
    });

    m.fors = [{
      id: 0,
      iterVars: [2],
      arrays: [0],
      stateVars: [3],
      stateInits: [1],
      body: 1,
      then: 2,
    }];

    m.agents = [{ id: 0, name: "test.sum", entry: 0 }];

    expect(runAndGet(m, "test.sum", [])).toBe(6);
  });

  // Test 7: Handle with internal request
  it("handle with request", () => {
    const m = emptyModule();
    m.consts = [
      { tag: "Int", value: 0 },
      { tag: "Int", value: 1 },
    ];

    m.requests = [{ id: 0, name: "inc", from: null }];

    // Thread 0 (FnBody): main
    m.threads.push({
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 10, cid: 0 },
        { op: "Handle", dst: 20, handleId: 0 },
        { op: "Complete", val: 20 },
      ],
    });

    // Thread 1 (HandlerTarget): body
    m.threads.push({
      id: 1, kind: "HandlerTarget", params: [],
      body: [
        { op: "Request", dst: 30, reqDefId: 0, args: [] },
        { op: "Complete", val: 30 },
      ],
    });

    // Thread 2 (RequestHandler): handler for request 0
    m.threads.push({
      id: 2, kind: "RequestHandler", params: [],
      body: [
        { op: "LoadConst", dst: 41, cid: 1 },
        { op: "Add", dst: 40, lhs: 11, rhs: 41 },
        { op: "Continue", val: 40, mutations: [[11, 40]] },
      ],
    });

    // Thread 3 (HandleThen)
    m.threads.push({
      id: 3, kind: "HandleThen", params: [50],
      body: [
        { op: "Complete", val: 50 },
      ],
    });

    m.handles = [{
      id: 0,
      stateVars: [11],
      stateInits: [10],
      body: 1,
      reqCases: [[0, 2]],
      then: 3,
    }];

    m.agents = [{ id: 0, name: "test.handle", entry: 0 }];

    expect(runAndGet(m, "test.handle", [])).toBe(1);
  });

  // Test 8: Par (parallel branches)
  it("par", () => {
    const m = emptyModule();
    m.consts = [{ tag: "Int", value: 10 }, { tag: "Int", value: 20 }];

    m.threads.push({
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "Par", dst: 5, threads: [1, 2] },
        { op: "Complete", val: 5 },
      ],
    });

    m.threads.push({
      id: 1, kind: "Block", params: [],
      body: [
        { op: "LoadConst", dst: 0, cid: 0 },
        { op: "Complete", val: 0 },
      ],
    });

    m.threads.push({
      id: 2, kind: "Block", params: [],
      body: [
        { op: "LoadConst", dst: 1, cid: 1 },
        { op: "Complete", val: 1 },
      ],
    });

    m.agents = [{ id: 0, name: "test.par", entry: 0 }];

    expect(runAndGet(m, "test.par", [])).toEqual([10, 20]);
  });

  // Test 9: Local agent call (non-primitive ICall)
  it("local agent call", () => {
    const m = emptyModule();
    m.consts = [{ tag: "Int", value: 5 }, { tag: "Int", value: 3 }];

    // Agent 0: test.double (v0 → v0 + v0)
    m.threads.push({
      id: 10, kind: "FnBody", params: [0],
      body: [
        { op: "Add", dst: 1, lhs: 0, rhs: 0 },
        { op: "Complete", val: 1 },
      ],
    });

    // Agent 1: test.main (calls test.double(5), adds 3)
    m.threads.push({
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 100, cid: 0 },
        { op: "Call", dst: 101, agentDefId: 0, args: [100] },
        { op: "LoadConst", dst: 102, cid: 1 },
        { op: "Add", dst: 103, lhs: 101, rhs: 102 },
        { op: "Complete", val: 103 },
      ],
    });

    m.agents = [
      { id: 0, name: "test.double", entry: 10 },
      { id: 1, name: "test.main", entry: 0 },
    ];

    expect(runAndGet(m, "test.main", [])).toBe(13);
  });

  // Test 10: String concat
  it("string operations", () => {
    const m = emptyModule();
    m.consts = [
      { tag: "Str", value: "hello " },
      { tag: "Str", value: "world" },
    ];
    m.threads = [{
      id: 0, kind: "FnBody", params: [],
      body: [
        { op: "LoadConst", dst: 0, cid: 0 },
        { op: "LoadConst", dst: 1, cid: 1 },
        { op: "Concat", dst: 2, lhs: 0, rhs: 1 },
        { op: "Complete", val: 2 },
      ],
    }];
    m.agents = [{ id: 0, name: "test.str", entry: 0 }];

    expect(runAndGet(m, "test.str", [])).toBe("hello world");
  });
});
