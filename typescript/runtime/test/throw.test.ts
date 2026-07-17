// End-to-end tests for the typed error model (`prelude.throw`): hand-built IR driven through the
// ProjectActor. A throw is an ordinary request raised by delegating to the `prelude.throw` wrapper (what
// a compiled raise lowers to), so it bubbles to a `prelude.throw` handler like any request — but at the
// run root it FAILS the run with its serialized payload (a `never` answer cannot be waited for). The
// suite pins: catch-and-break recovery, the rethrow path (a handler body's raise must escape its own
// handle — the self-catch guard), the run-failure message with redaction, a real prim's typed throw
// (`json.parse`), and the panic/throw split (a throw handler does not catch a panic).

import {
  createAgentName,
  type IRModule,
  type Operation,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import { markPrivate } from "../src/runtime/value/privacy.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-throw" as ProjectId;
const SNAPSHOT = "snapshot-throw" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };
const THROW = createAgentName("prelude.throw");

/** The `prelude.throw` wrapper pair a compiled raise delegates to: its agent entry + the request leaf. */
function throwWrapper(agentId: number, leafId: number, inputVar: number) {
  return {
    [agentId]: {
      block: { kind: "agent", body: leafId, schema: EMPTY_SCHEMA, defaults: {} },
      parameters: {},
    },
    [leafId]: {
      block: { kind: "request", name: THROW, input: inputVar },
      parameters: { parameter: inputVar },
    },
  } as const;
}

function run(
  ir: IRModule,
  argument: Value | null,
  prims: PrimRegistry = new PrimRegistry(),
): Promise<Value> {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  const actor = new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims,
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
  return actor.startRun(createAgentName("main"), SNAPSHOT, argument).result;
}

/** `{ error: { message } }` raise operations: build the payload record and delegate to `prelude.throw`.
 *  Emits into `output` (never reached — the raise does not return). */
function raiseOperations(message: string, base: number, output: number): Operation[] {
  return [
    { kind: "loadLiteral", output: base, value: { kind: "string", value: message } },
    { kind: "makeRecord", entries: [["message", base]], output: base + 1 },
    { kind: "makeRecord", entries: [["error", base + 1]], output: base + 2 },
    {
      kind: "delegate",
      target: { kind: "name", name: THROW },
      argument: base + 2,
      output,
    },
  ];
}

describe("the typed error model (prelude.throw)", () => {
  test("a throw is caught by a `prelude.throw` handler that breaks with a recovery value", async () => {
    // agent main() { handle { throw({message:"boom"}) } with throw(e) => break -1 }
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
          parameters: { parameter: 99 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: THROW, body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: { kind: "sequence", result: 23, operations: [...raiseOperations("boom", 20, 23)] },
          parameters: {},
        },
        // handler body: break -1 (a throw answers with `never`, so recovery always escapes the handle)
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
        ...throwWrapper(5, 6, 50),
      },
      entries: { [createAgentName("main")]: { block: 0, private: false }, [THROW]: { block: 5, private: false } },
      names: {},
    };

    await expect(run(ir, null)).resolves.toEqual({ kind: "integer", value: -1 });
  });

  test("a handler body's rethrow escapes its own handle to the outer one (no self-catch)", async () => {
    // agent main() {
    //   handle {                                  // outer: throw(e) => break -2
    //     handle { throw({message:"inner"}) }     // inner: throw(e) => throw({message:"rethrown"})
    //     with throw(e) => throw({message:"rethrown"})
    //   } with throw(e) => break -2
    // }
    // The inner handler rethrows; were the inner handle to re-match its own handler's raise, this would
    // loop forever. The outer handler must receive it and break.
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
          parameters: { parameter: 99 },
        },
        // outer handle
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: THROW, body: 7 }],
            thenClause: null,
          },
          parameters: {},
        },
        // outer body: call the inner handle
        3: {
          block: {
            kind: "sequence",
            result: 30,
            operations: [{ kind: "call", target: 4, output: 30 }],
          },
          parameters: {},
        },
        // inner handle
        4: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 5,
            handlers: [{ request: THROW, body: 6 }],
            thenClause: null,
          },
          parameters: {},
        },
        5: {
          block: { kind: "sequence", result: 53, operations: [...raiseOperations("inner", 50, 53)] },
          parameters: {},
        },
        // inner handler body: rethrow with a new payload
        6: {
          block: { kind: "sequence", result: 63, operations: [...raiseOperations("rethrown", 60, 63)] },
          parameters: { parameter: 64 },
        },
        // outer handler body: break -2
        7: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 70, value: { kind: "integer", value: -2 } },
              { kind: "exit", target: 2, value: 70 },
            ],
          },
          parameters: { parameter: 71 },
        },
        ...throwWrapper(8, 9, 80),
      },
      entries: { [createAgentName("main")]: { block: 0, private: false }, [THROW]: { block: 8, private: false } },
      names: {},
    };

    await expect(run(ir, null)).resolves.toEqual({ kind: "integer", value: -2 });
  });

  test("an unhandled throw fails the run with the serialized payload", async () => {
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: { kind: "sequence", result: null, operations: [...raiseOperations("boom", 20, 23), { kind: "exit", target: 0, value: 23 }] },
          parameters: { parameter: 99 },
        },
        ...throwWrapper(5, 6, 50),
      },
      entries: { [createAgentName("main")]: { block: 0, private: false }, [THROW]: { block: 5, private: false } },
      names: {},
    };

    await expect(run(ir, null)).rejects.toThrow(/throw: .*"message":"boom"/);
  });

  test("a tainted payload is redacted in the run's error message (fail-closed boundary)", async () => {
    // main: throw({ message: secret() }) — the payload's field is private, so the failure message must
    // carry `$redacted`, never the plaintext.
    const prims = new PrimRegistry();
    prims.register("test.secret", () => markPrivate({ kind: "string", value: "hunter2" }));
    const ir: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, defaults: {} }, parameters: {} },
        1: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "makeRecord", entries: [], output: 19 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("test.secret") },
                argument: 19,
                output: 20,
              },
              { kind: "makeRecord", entries: [["message", 20]], output: 21 },
              { kind: "makeRecord", entries: [["error", 21]], output: 22 },
              { kind: "delegate", target: { kind: "name", name: THROW }, argument: 22, output: 23 },
              { kind: "exit", target: 0, value: 23 },
            ],
          },
          parameters: { parameter: 99 },
        },
        ...throwWrapper(5, 6, 50),
        ...primitiveWrapper(7, 8, 70, "test.secret"),
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [THROW]: { block: 5, private: false },
        [createAgentName("test.secret")]: { block: 7, private: false },
      },
      names: {},
    };

    const failure = run(ir, null, prims);
    await expect(failure).rejects.toThrow(/throw: .*\$redacted/);
    await expect(failure).rejects.not.toThrow(/hunter2/);
  });

  test("json.parse's malformed-text failure is a catchable typed throw", async () => {
    // agent main() { handle { json.parse("{oops") } with throw(e) => break -3 }
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
          parameters: { parameter: 99 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: THROW, body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 23,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "string", value: "{oops" } },
              { kind: "makeRecord", entries: [["text", 20]], output: 21 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.json.parse") },
                argument: 21,
                output: 23,
              },
            ],
          },
          parameters: {},
        },
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: -3 } },
              { kind: "exit", target: 2, value: 40 },
            ],
          },
          parameters: { parameter: 41 },
        },
        ...primitiveWrapper(5, 6, 50, "prelude.json.parse"),
      },
      entries: { [createAgentName("main")]: { block: 0, private: false }, [createAgentName("prelude.json.parse")]: { block: 5, private: false } },
      names: {},
    };

    await expect(run(ir, null)).resolves.toEqual({ kind: "integer", value: -3 });
  });

  test("a division by zero is a panic — a throw handler does not catch it, and the run fails", async () => {
    // agent main() { handle { 1 / 0 } with throw(e) => break -4 }: the handler must NOT catch a panic
    // (the runtime's own failure signal is not the typed error channel), so the run fails.
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
          parameters: { parameter: 99 },
        },
        2: {
          block: {
            kind: "handle",
            parallel: false,
            initialStates: [],
            body: 3,
            handlers: [{ request: THROW, body: 4 }],
            thenClause: null,
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 24,
            operations: [
              { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 1 } },
              { kind: "loadLiteral", output: 21, value: { kind: "integer", value: 0 } },
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
                target: { kind: "name", name: createAgentName("prelude.divide") },
                argument: 22,
                output: 24,
              },
            ],
          },
          parameters: {},
        },
        4: {
          block: {
            kind: "sequence",
            result: null,
            operations: [
              { kind: "loadLiteral", output: 40, value: { kind: "integer", value: -4 } },
              { kind: "exit", target: 2, value: 40 },
            ],
          },
          parameters: { parameter: 41 },
        },
        ...primitiveWrapper(5, 6, 50, "prelude.divide"),
      },
      entries: { [createAgentName("main")]: { block: 0, private: false }, [createAgentName("prelude.divide")]: { block: 5, private: false } },
      names: {},
    };

    await expect(run(ir, null)).rejects.toThrow(/panic: division by zero/);
  });
});

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
