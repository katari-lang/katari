// End-to-end smoke test for the in-memory core: hand-built IR driven through the ProjectActor, with no
// compiler and no DB. Exercises the uniform delegate model (every primitive is a child instance), the
// internal turn loop, structural nodes (for / match), control flow (return), and the value model.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import {
  type ExternalRunner,
  InProcessExternalRunner,
  StubExternalRunner,
} from "../src/runtime/external/runner.js";
import { RuntimeHost } from "../src/runtime/host.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
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

function run(
  ir: IRModule,
  entry: string,
  argument: Value | null,
  external: ExternalRunner = new StubExternalRunner(),
): Promise<Value> {
  const registry = new SnapshotRegistry();
  registry.set(SNAPSHOT, ir);
  const actor = new ProjectActor({
    projectId: PROJECT,
    registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external,
    persistence: new InMemoryPersistence(),
  });
  return actor.startRun(createAgentName(entry), SNAPSHOT, argument);
}

describe("in-memory core", () => {
  test("returns an arithmetic result through the uniform delegate model", async () => {
    // agent main() { return 1 + 2 }   (every `+` is a delegate to a `primitive.add` child instance)
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
                target: { kind: "name", name: createAgentName("primitive.add") },
                argument: 4,
                output: 5,
              },
              { kind: "exit", target: 0, value: 5 },
            ],
          },
          parameters: { parameter: 1 },
        },
        ...primitiveWrapper(6, 7, 8, "primitive.add"),
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("primitive.add")]: 6,
      },
      names: {},
    };

    await expect(run(ir, "main", null)).resolves.toEqual({ kind: "integer", value: 3 });
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
                target: { kind: "name", name: createAgentName("primitive.multiply") },
                argument: 23,
                output: 22,
              },
            ],
          },
          parameters: { iterator: 20 },
        },
        ...primitiveWrapper(6, 7, 8, "primitive.multiply"),
      },
      entries: {
        [createAgentName("triple")]: 0,
        [createAgentName("primitive.multiply")]: 6,
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
    // agent main() { return greet({ name: "world" }) }   (greet is an external agent — a child instance
    // whose body is an ExternalThread that dispatches through the single ExternalRunner and suspends)
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
          block: { kind: "external", key: "greet", input: 8 },
          parameters: { parameter: 8 },
        },
      },
      entries: {
        [createAgentName("main")]: 0,
        [createAgentName("greet")]: 6,
      },
      names: {},
    };

    const external = new InProcessExternalRunner({
      greet: (argument) => {
        const name =
          argument?.kind === "record" && argument.fields.name?.kind === "string"
            ? argument.fields.name.value
            : "stranger";
        return { kind: "string", value: `Hello, ${name}` };
      },
    });

    await expect(run(ir, "main", null, external)).resolves.toEqual({
      kind: "string",
      value: "Hello, world",
    });
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

  test("runs through the RuntimeHost composition root", async () => {
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

    const host = new RuntimeHost();
    host.registerSnapshot(SNAPSHOT, ir);
    await expect(host.startRun(PROJECT, createAgentName("answer"), SNAPSHOT, null)).resolves.toEqual({
      kind: "integer",
      value: 42,
    });
  });
});
