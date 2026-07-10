// End-to-end smoke test for the in-memory core: hand-built IR driven through the ProjectActor, with no
// compiler and no DB. Exercises the uniform delegate model (every primitive is a child instance), the
// internal turn loop, structural nodes (for / match), control flow (return), and the value model.

import { createAgentName, type IRModule, type QualifiedName, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor, RunCancelledError } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import {
  type FfiCompletion,
  type FfiTransport,
  InProcessFfiTransport,
  StubFfiTransport,
} from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { ProjectRegistry } from "../src/runtime/registry.js";
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-smoke" as ProjectId;
const SNAPSHOT = "snapshot-smoke" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** A leaf primitive wrapped in its agent: `entries[name] -> agent -> BlockPrimitive`. Two block ids. */
function primitiveWrapper(agentId: number, leafId: number, inputVar: number, name: string) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "primitive", name, input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

/** Register one hand-built IRModule under every module its entries name (so a cross-module name like
 *  `prelude.add` resolves to module `primitive`, `main` to the empty user module — both point here). */
function registerModules(registry: SnapshotRegistry, ir: IRModule): void {
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
}

function makeActor(ir: IRModule, external: FfiTransport = new StubFfiTransport()): ProjectActor {
  const registry = new SnapshotRegistry();
  registerModules(registry, ir);
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external,
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
}

function run(
  ir: IRModule,
  entry: string,
  argument: Value | null,
  external: FfiTransport = new StubFfiTransport(),
): Promise<Value> {
  return makeActor(ir, external).startRun(createAgentName(entry), SNAPSHOT, argument).result;
}

/** Spin the event loop until `predicate` holds (the actor pumps its mailbox asynchronously). */
async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("in-memory core", () => {
  test("returns an arithmetic result through the uniform delegate model", async () => {
    // agent main() { return 1 + 2 }   (every `+` is a delegate to a `prelude.add` child instance)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 3, value: { kind: "integer", value: 2 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 2],
                  ["right", 3],
                ],
                output: 4,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(6, 7, 8, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 3 });
  });

  test("executes compiler-inserted drops and still computes the same result", async () => {
    // The arithmetic program above with the liveness pass's drops interleaved: the operand literals die
    // at the makeRecord, the argument record at the delegate. Later operations must still read the
    // bindings that stay live (the delegate reads 4 after [2, 3] dropped; the exit reads 5 after [4]).
    const ir: IRModule = {
      metadata: { schemaVersion: 2 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 3, value: { kind: "integer", value: 2 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 2],
                  ["right", 3],
                ],
                output: 4,
              },
              { kind: "drop", variables: [2, 3] },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 4,
                output: 5,
              },
              { kind: "drop", variables: [4] },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(6, 7, 8, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 3 });
  });

  test("a drop deletes the binding from the local scope only, never up the chain", async () => {
    // A hand-built probe of the runtime semantics (compiler output never reuses a VariableId): the
    // agent body binds variable 20 to 1, then enters a child sequence that shadows 20 with 2 and drops
    // it. The child's result read of 20 must fall back through the scope chain to the parent's 1 —
    // proving the drop really deleted the child's own binding, and deleted nothing above it.
    const ir: IRModule = {
      metadata: { schemaVersion: 2 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 1 } },
              { kind: "call", target: 2, output: 21 },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "sequence",
            result: 20,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 2 } },
              { kind: "drop", variables: [20] },
            ],
          },
          parameters: {},
        },
      },
      entries: { [createAgentName("main")]: 0 },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 1 });
  });

  test("maps a sequential for loop over an array argument", async () => {
    // agent triple(xs) { for (x in xs) { x * 3 } }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        // triple agent + body
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "xs", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        // for node
        2: {
          block: {
            kind: "for",
            parallel: false,
            source: 11,
            initialStates: [],
            body: 3,
            thenClause: null,
          },
          parameters: {},
        },
        // for body: x * 3  (falls through with the product => mapped value)
        3: {
          block: {
            kind: "sequence",
            result: 22,
            operations: [
              { kind: "loadLiteral", output: 21, value: { kind: "integer", value: 3 } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 20],
                  ["right", 21],
                ],
                output: 23,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.multiply") },
                argument: 23,
                output: 22,
              },
            ],
          },
          parameters: { iterator: 20 },
        },
        ...primitiveWrapper(6, 7, 8, "prelude.multiply"),
      },
      entries: {
        [createAgentName("triple")]: 0,
        [createAgentName("prelude.multiply")]: 6,
      },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      fields: {
        xs: {
          kind: "array",
          elements: [
            { kind: "integer", value: 1 },
            { kind: "integer", value: 2 },
            { kind: "integer", value: 4 },
          ],
        },
      },
    };
    await expect(run(ir, "triple", argument)).resolves.toEqual({
      kind: "array",
      elements: [
        { kind: "integer", value: 3 },
        { kind: "integer", value: 6 },
        { kind: "integer", value: 12 },
      ],
    });
  });

  test("collects a nested next-for, tearing its iteration subtree down via the cancel cascade", async () => {
    // agent echo(xs) { for (x in xs) { match x { v => next-for v } } }
    // The `next-for` is raised from inside a match arm (a nested structural node), so it bubbles two
    // proxy hops to the for, which cancels the whole iteration subtree (body sequence + match + arm) and
    // collects the value on its teardown — no ad-hoc drop that would leak the match subtree.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "xs", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "for",
            parallel: false,
            source: 11,
            initialStates: [],
            body: 3,
            thenClause: null,
          },
          parameters: {},
        },
        // for body: call into a match over the iterator (the arm raises the next-for)
        3: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "call", target: 4, output: 30 }],
          },
          parameters: { iterator: 20 },
        },
        4: {
          block: {
            kind: "match",
            subject: 20,
            arms: [{ pattern: { kind: "variable", variable: 40 }, body: 5 }],
            fallback: null,
          },
          parameters: {},
        },
        // match arm: next-for the bound value (targets the for block)
        5: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "continue", target: 2, value: 40, modifiers: [] }],
          },
          parameters: {},
        },
      },
      entries: { [createAgentName("echo")]: 0 },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      fields: {
        xs: {
          kind: "array",
          elements: [
            { kind: "integer", value: 1 },
            { kind: "integer", value: 2 },
            { kind: "integer", value: 3 },
          ],
        },
      },
    };
    await expect(run(ir, "echo", argument)).resolves.toEqual({
      kind: "array",
      elements: [
        { kind: "integer", value: 1 },
        { kind: "integer", value: 2 },
        { kind: "integer", value: 3 },
      ],
    });
  });

  test("breaks out of a for from inside a match arm, returning the break value past the then-clause", async () => {
    // agent pick(xs) {
    //   for (x in xs) { match x { 2 => break-for 99; v => next-for v } } then (result) { -1 }
    // }
    // Mirrors the real `infer_with_tools` tool loop: earlier iterations `next-for` (so a mapping is
    // collected), then a match arm `break-for`s a value. The break must short-circuit the whole loop to
    // that value — bypassing BOTH the then-clause reducer (-1) and the collected mapping ([1]). A prior
    // bug ran the then-clause on break-for, so the loop yielded the fallback and the break value was lost.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "xs", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "for",
            parallel: false,
            source: 11,
            initialStates: [],
            body: 3,
            thenClause: { body: 7 },
          },
          parameters: {},
        },
        // for body: call into a match over the iterator (its arms raise break-for / next-for)
        3: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "call", target: 4, output: 30 }],
          },
          parameters: { iterator: 20 },
        },
        4: {
          block: {
            kind: "match",
            subject: 20,
            arms: [
              { pattern: { kind: "literal", value: { kind: "integer", value: 2 } }, body: 5 },
              { pattern: { kind: "variable", variable: 40 }, body: 6 },
            ],
            fallback: null,
          },
          parameters: {},
        },
        // arm x == 2: break-for 99 (exit targeting the for block)
        5: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 50, value: { kind: "integer", value: 99 } },
              { kind: "exit", target: 2, value: 50 },
            ],
          },
          parameters: {},
        },
        // arm v: next-for v (collect it into the mapping the break must discard)
        6: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "continue", target: 2, value: 40, modifiers: [] }],
          },
          parameters: {},
        },
        // then-clause: the fallback the break must bypass (reads the mapping via `result`, ignores it)
        7: {
          block: {
            kind: "sequence",
            result: 71,
            operations: [{ kind: "loadLiteral", output: 71, value: { kind: "integer", value: -1 } }],
          },
          parameters: { result: 70 },
        },
      },
      entries: { [createAgentName("pick")]: 0 },
      names: {},
    };

    const argument: Value = {
      kind: "record",
      fields: {
        xs: {
          kind: "array",
          elements: [
            { kind: "integer", value: 1 },
            { kind: "integer", value: 2 },
            { kind: "integer", value: 3 },
          ],
        },
      },
    };
    await expect(run(ir, "pick", argument)).resolves.toEqual({ kind: "integer", value: 99 });
  });

  test("selects a match arm and binds its pattern variable", async () => {
    // agent classify(n) { match n { 0 => "zero"; m => "other" } }   (over the record field `n`)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "n", output: 11 },
              { kind: "call", target: 2, output: 12 },
              { kind: "exit", target: 0, value: 12 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "match",
            subject: 11,
            arms: [
              { pattern: { kind: "literal", value: { kind: "integer", value: 0 } }, body: 3 },
              { pattern: { kind: "variable", variable: 30 }, body: 4 },
            ],
            fallback: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 31,
            operations: [
              { kind: "loadLiteral", output: 31, value: { kind: "string", value: "zero" } },
            ],
          },
          parameters: {},
        },
        4: {
          block: {
            kind: "sequence",
            result: 41,
            operations: [
              { kind: "loadLiteral", output: 41, value: { kind: "string", value: "other" } },
            ],
          },
          parameters: {},
        },
      },
      entries: { [createAgentName("classify")]: 0 },
      names: {},
    };

    await expect(
      run(ir, "classify", { kind: "record", fields: { n: { kind: "integer", value: 0 } } }),
    ).resolves.toEqual({ kind: "string", value: "zero" });
    await expect(
      run(ir, "classify", { kind: "record", fields: { n: { kind: "integer", value: 7 } } }),
    ).resolves.toEqual({ kind: "string", value: "other" });
  });

  test("suspends on an external (FFI) leaf and resumes from its completion", async () => {
    // agent main() { return greet({ name: "world" }) }   (greet is an external agent — its body is an
    // ExternalThread proxy that delegates to the `ffi` reactor, which dispatches through the transport)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "string", value: "world" } },
              { kind: "makeRecord", entries: [["name", 2]], output: 3 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("greet") },
                argument: 3,
                output: 4,
              },
              { kind: "exit", target: 0, value: 4 },
            ],
          },
          parameters: { parameter: 1 },
        },
        // greet external agent + its external leaf body
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: {
          block: { kind: "external", key: "greet", input: 8, reactor: "ffi" },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("greet")]: 6,
      },
      names: {},
    };

    // The FFI handler sees a plain Json argument (the ffi reactor lowers the Value) and returns plain Json.
    const external = new InProcessFfiTransport({
      greet: (argument) => {
        const name =
          typeof argument === "object" &&
          argument !== null &&
          !Array.isArray(argument) &&
          typeof argument.name === "string"
            ? argument.name
            : "stranger";
        return `Hello, ${name}`;
      },
    });

    await expect(run(ir, "main", null, external)).resolves.toEqual({
      kind: "string",
      value: "Hello, world",
    });
  });

  test("aborts an in-flight external call on cancel, completing only once the runner confirms", async () => {
    // agent main() { par [ greet({}), return 7 ] }
    // The `return 7` cancels the par; that terminates greet's instance, whose external proxy delegates an
    // in-flight ffi call. The cancel is graceful: it `terminate`s the ffi call, which the transport confirms
    // with a `cancelled` completion. The run resolves to 7 only after that confirmation (so it would *hang*
    // if the abort were not wired), and the transport saw exactly one abort.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "call", target: 2, output: 10 }],
          },
          parameters: { parameter: 11 },
        },
        2: { block: { kind: "parallel", elements: [3, 4] }, parameters: {} },
        // element 0: greet({}) — an external call that never resolves
        3: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 30 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("greet") },
                argument: 30,
                output: 31,
              },
            ],
          },
          parameters: {},
        },
        // element 1: return 7 (cancels the par, and with it the in-flight external)
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: 7 } },
              { kind: "exit", target: 0, value: 40 },
            ],
          },
          parameters: {},
        },
        6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        7: { block: { kind: "external", key: "greet", input: 8, reactor: "ffi" }, parameters: { parameter: 8 } },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("greet")]: 6,
      },
      names: {},
    };

    // A transport whose dispatch never completes; its `abort` records the call and reports the abort.
    const aborted: DelegationId[] = [];
    let sink: ((completion: FfiCompletion) => void) | null = null;
    const external: FfiTransport = {
      onComplete(register) {
        sink = register;
      },
      onDelegate() {},
      dispatch() {
        // never resolves
      },
      recover() {},
      close() {},
      abort(delegation) {
        aborted.push(delegation);
        sink?.({ delegation, outcome: { kind: "cancelled" } });
      },
      deliverDelegateResult() {},
    };

    await expect(run(ir, "main", null, external)).resolves.toEqual({ kind: "integer", value: 7 });
    expect(aborted).toHaveLength(1);
  });

  test("keeps a returned closure callable after its producer retires (scope ascent)", async () => {
    // agent makeConst(n) { return () => n }   agent main() { let f = makeConst(5); return f() }
    // makeConst returns a closure capturing its body scope (where n = 5), then retires. Its scope must
    // ascend to main rather than be dropped, so calling the closure later still resolves n -> 5. (Without
    // ascent the scope is gone and `n` reads null.)
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 60, value: { kind: "integer", value: 5 } },
              { kind: "makeRecord", entries: [["n", 60]], output: 61 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("makeConst") },
                argument: 61,
                output: 62,
              },
              { kind: "makeRecord", entries: [], output: 63 },
              // Call the returned closure value (the producer makeConst is gone by now).
              { kind: "delegate", target: { kind: "value", variable: 62 }, argument: 63, output: 64 },
              { kind: "exit", target: 0, value: 64 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: { block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        // makeConst body: capture the scope holding n and return a closure over it
        3: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "getField", source: 10, field: "n", output: 20 },
              { kind: "makeClosure", output: 30, agent: 4 },
              { kind: "exit", target: 2, value: 30 },
            ],
          },
          parameters: { parameter: 10 },
        },
        4: { block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        // closure body: return n, read from the captured (ascended) scope of makeConst
        5: {
          block: {
            kind: "sequence",
            result: null,
            operations: [{ kind: "exit", target: 4, value: 20 }],
          },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("makeConst")]: 2,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 5 });
  });

  test("dispatches a request to a handler and resumes via next", async () => {
    // agent main() { handle { ask_value({ value: 7 }) } with ask_value(p) => { next 100 } }
    // The body raises ask_value (a request, summoned as a child instance); it escalates out of that
    // instance, the handle catches it, the handler `next`s 100, which resumes the request -> 100.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 2, output: 10 },
              { kind: "exit", target: 0, value: 10 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: createAgentName("ask_value"), body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        // handle body: ask_value({ value: 7 })  (its result is the request's answer)
        3: {
          block: {
            kind: "sequence",
            result: 22,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 7 } },
              { kind: "makeRecord", entries: [["value", 20]], output: 21 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 21,
                output: 22,
              },
            ],
          },
          parameters: {},
        },
        // handler body: next 100
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: 100 } },
              { kind: "continue", target: 2, value: 40, modifiers: [] },
            ],
          },
          parameters: { parameter: 41 },
        },
        // ask_value request agent + its request leaf
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: { kind: "request", name: createAgentName("ask_value"), input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 5,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 100 });
  });

  test("resumes via an implicit next when a handler body falls through to its tail", async () => {
    // agent main() { handle { ask_value({ value: 7 }) } with ask_value(p) => { 100 } }
    // The handler body has no explicit `next`/`break`: it falls through with tail value 100, which is an
    // implicit `next` (resume) — so the request answers 100, exactly like the explicit-next variant above.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 2, output: 10 },
              { kind: "exit", target: 0, value: 10 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: createAgentName("ask_value"), body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 22,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 7 } },
              { kind: "makeRecord", entries: [["value", 20]], output: 21 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 21,
                output: 22,
              },
            ],
          },
          parameters: {},
        },
        // handler body: falls through with tail value 100 (result = 40, no explicit continue/exit)
        4: {
          block: {
            kind: "sequence",
            result: 40,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: 100 } },
            ],
          },
          parameters: { parameter: 41 },
        },
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: { kind: "request", name: createAgentName("ask_value"), input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 5,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 100 });
  });

  test("breaks out of a handle, terminating the suspended request's instance", async () => {
    // agent main() { handle { ask_value({}) } with ask_value(p) => { break 99 } }
    // The handler `break`s instead of `next`ing: the handle exits with 99 and the request's still-
    // suspended child instance is terminated by the cancel cascade.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 2, output: 10 },
              { kind: "exit", target: 0, value: 10 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: createAgentName("ask_value"), body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 22,
            operations: [
              { kind: "makeRecord", entries: [], output: 21 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 21,
                output: 22,
              },
            ],
          },
          parameters: {},
        },
        // handler body: break 99  (exit targeting the handle block)
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: 99 } },
              { kind: "exit", target: 2, value: 40 },
            ],
          },
          parameters: { parameter: 41 },
        },
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: { kind: "request", name: createAgentName("ask_value"), input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 5,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 99 });
  });

  test("fails the run with a panic when a primitive errors unhandled", async () => {
    // agent main() { add({ left: 1, right: "x" }) }  — the add prim panics (string is not a number),
    // and with no handler the panic reaches the run root and rejects it.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 3, value: { kind: "string", value: "x" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 2],
                  ["right", 3],
                ],
                output: 4,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(6, 7, 8, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).rejects.toThrow(/panic.*number/);
  });

  test("fails the run (not hangs) when the run's agent cannot be resolved", async () => {
    // `katari run missing.agent` — the run-root delegate resolves to no IR. A deterministic failure must
    // fail the run as a panic, never throw from `react` (which the substrate would treat as a transient
    // poison and replay-loop forever — a silent hang). The run's `result` rejects with the resolution error.
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: 2,
            operations: [{ kind: "loadLiteral", output: 2, value: { kind: "integer", value: 1 } }],
          },
          parameters: { parameter: 1 },
        },
      },
      entries: { [createAgentName("main")]: 0 }, // only `main` exists — `missing.agent` does not
      names: {},
    };

    await expect(run(ir, "missing.agent", null)).rejects.toThrow(/no IR for module/i);
  });

  test("catches a panic with a handler", async () => {
    // agent main() { handle { add({ left: 1, right: "x" }) } with panic(e) => break -1 }
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "call", target: 2, output: 10 },
              { kind: "exit", target: 0, value: 10 },
            ],
          },
          parameters: { parameter: 11 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: createAgentName("prelude.panic"), body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 23,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 21, value: { kind: "string", value: "x" } },
              {
                kind: "makeRecord",
                entries: [
                  ["left", 20],
                  ["right", 21],
                ],
                output: 22,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.add") },
                argument: 22,
                output: 23,
              },
            ],
          },
          parameters: {},
        },
        // handler body: break -1
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: -1 } },
              { kind: "exit", target: 2, value: 40 },
            ],
          },
          parameters: { parameter: 41 },
        },
        ...primitiveWrapper(6, 7, 8, "prelude.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("prelude.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: -1 });
  });

  // agent main() { ask_value({}) }  — ask_value has no handler, so it escalates all the way to the run
  // root, where the engine keeps it open (the run suspends) instead of failing the run.
  function runRootRequestIr(): IRModule {
    return {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 20 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("ask_value") },
                argument: 20,
                output: 21,
              },
              { kind: "exit", target: 0, value: 21 },
            ],
          },
          parameters: { parameter: 11 },
        },
        5: { block: { kind: "agent", body: 6, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        6: {
          block: { kind: "request", name: createAgentName("ask_value"), input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("ask_value")]: 5,
      },
      names: {},
    };
  }

  test("keeps a run-root request open and resumes the run when it is answered", async () => {
    const actor = makeActor(runRootRequestIr());
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const open = await waitUntil(() => {
      const list = actor.listOpenEscalations();
      return list.length > 0 ? list : undefined;
    });
    expect(open).toHaveLength(1);
    expect(open[0]?.request).toBe(createAgentName("ask_value"));
    expect(open[0]?.argument).toEqual({ kind: "record", fields: {} });

    const escalation = open[0]?.escalation;
    if (escalation === undefined) throw new Error("no open escalation");
    actor.answerEscalation(escalation, { kind: "integer", value: 42 });
    await expect(result).resolves.toEqual({ kind: "integer", value: 42 });
    expect(actor.listOpenEscalations()).toHaveLength(0);
  });

  test("cancels a suspended run, rejecting its result with RunCancelledError", async () => {
    const actor = makeActor(runRootRequestIr());
    const { run: runDelegation, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    await waitUntil(() => (actor.listOpenEscalations().length > 0 ? true : undefined));
    actor.cancelRun(runDelegation, "user requested");

    await expect(result).rejects.toBeInstanceOf(RunCancelledError);
    expect(actor.listOpenEscalations()).toHaveLength(0);
  });

  test("runs through the ProjectRegistry composition root", async () => {
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: 2,
            operations: [{ kind: "loadLiteral", output: 2, value: { kind: "integer", value: 42 } }],
          },
          parameters: { parameter: 1 },
        },
      },
      entries: { [createAgentName("answer")]: 0 },
      names: {},
    };

    const registry = new ProjectRegistry();
    registry.registerModule(SNAPSHOT, "", ir); // the `answer` agent lives in the empty (user) module
    const { run, result } = registry
      .actorFor(PROJECT)
      .startRun(createAgentName("answer"), SNAPSHOT, null);
    expect(typeof run).toBe("string"); // the run delegation id — the durable run handle
    await expect(result).resolves.toEqual({ kind: "integer", value: 42 });
  });
});
