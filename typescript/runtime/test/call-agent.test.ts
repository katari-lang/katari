// The delegate acceptance surface: schema validation of every delegation's argument, and the
// `call_agent` unwrap (a delegate to `prelude.call_agent` re-targets, under the same delegation, the
// callable its argument carries — so the dynamically dispatched args hit the same validation). Driven
// through the actor over hand-built IR, like `engine-smoke.test.ts`.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-call-agent" as ProjectId;
const SNAPSHOT = "snapshot-call-agent" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

const GREETER_SCHEMA: SchemaInfo = {
  input: {
    type: "object",
    properties: { name: { type: "string" } },
    required: ["name"],
    additionalProperties: true,
  },
  output: { type: "string" },
  requests: [],
  genericBindings: {},
};

/**
 * The shared fixture:
 *   agent greeter(name: string) -> string { name }        (input schema pins `name`)
 *   agent main(args) { call_agent(target = greeter, args = args) }
 * `main` loads `greeter` as a VALUE, wraps it with the caller-supplied `args` record, and delegates to
 * `prelude.call_agent` — whose leaf body must never run (the acceptance surface unwraps it).
 */
function fixture(): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: {
        block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      1: {
        block: {
          kind: "sequence",
          result: null,
          operations: [
            { kind: "getField", source: 10, field: "args", output: 11 },
            { kind: "loadAgent", output: 12, name: createAgentName("greeter") },
            {
              kind: "makeRecord",
              entries: [
                ["target", 12],
                ["args", 11],
              ],
              output: 13,
            },
            {
              kind: "delegate",
              target: { kind: "name", name: createAgentName("prelude.ai.call_agent") },
              argument: 13,
              output: 14,
            },
            { kind: "exit", target: 0, value: 14 },
          ],
        },
        parameters: { parameter: 10 },
      },
      // greeter: returns its `name` parameter.
      2: {
        block: { kind: "agent", body: 3, schema: GREETER_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      3: {
        block: {
          kind: "sequence",
          result: 21,
          operations: [{ kind: "getField", source: 20, field: "name", output: 21 }],
        },
        parameters: { parameter: 20 },
      },
      // prelude.call_agent: the leaf the stdlib lowers — reachable only if the unwrap fails.
      4: {
        block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
        parameters: {},
      },
      5: {
        block: { kind: "primitive", name: "prelude.ai.call_agent", input: 50 },
        parameters: { parameter: 50 },
      },
    },
    entries: {
      [createAgentName("main")]: 0,
      [createAgentName("greeter")]: 2,
      [createAgentName("prelude.ai.call_agent")]: 4,
    },
    names: {},
  };
}

function actorFor(ir: IRModule): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    persistence: new InMemoryPersistence(),
  });
}

function runMain(ir: IRModule, argument: Value | null): Promise<Value> {
  return actorFor(ir).startRun(createAgentName("main"), SNAPSHOT, argument).result;
}

function argsOf(fields: Record<string, Value>): Value {
  return { kind: "record", fields: { args: { kind: "record", fields } } };
}

describe("call_agent dispatch", () => {
  test("dispatches a callable value with a runtime-built args record", async () => {
    await expect(
      runMain(fixture(), argsOf({ name: { kind: "string", value: "alice" } })),
    ).resolves.toEqual({ kind: "string", value: "alice" });
  });

  test("panics when the args do not conform to the target's input schema", async () => {
    await expect(runMain(fixture(), argsOf({ wrong: { kind: "string", value: "oops" } }))).rejects.toThrow(
      /greeter.*input schema.*missing required field "name"/,
    );
  });

  test("panics when the args carry a wrongly-typed field", async () => {
    await expect(runMain(fixture(), argsOf({ name: { kind: "integer", value: 3 } }))).rejects.toThrow(
      /\$\.name/,
    );
  });

  test("panics when the target is not a callable value", async () => {
    // main variant: `call_agent(target = 42, args = {})` — the target field is a plain integer.
    const ir = fixture();
    ir.blocks[1] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 12, value: { kind: "integer", value: 42 } },
          { kind: "makeRecord", entries: [], output: 11 },
          {
            kind: "makeRecord",
            entries: [
              ["target", 12],
              ["args", 11],
            ],
            output: 13,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.ai.call_agent") },
            argument: 13,
            output: 14,
          },
          { kind: "exit", target: 0, value: 14 },
        ],
      },
      parameters: { parameter: 10 },
    };
    await expect(runMain(ir, null)).rejects.toThrow(/call_agent.*not a callable value/);
  });
});

describe("delegate argument validation", () => {
  test("a static delegate with a conforming argument runs (and an open schema stays permissive)", async () => {
    // Covered broadly by the untouched engine-smoke suite (every prim call passes `{}` schemas); this
    // pins the schema-carrying path: a direct run of greeter with a valid argument.
    await expect(
      actorFor(fixture()).startRun(createAgentName("greeter"), SNAPSHOT, {
        kind: "record",
        fields: { name: { kind: "string", value: "bob" } },
      }).result,
    ).resolves.toEqual({ kind: "string", value: "bob" });
  });

  test("a run whose argument violates the entry agent's schema fails as a panic", async () => {
    await expect(
      actorFor(fixture()).startRun(createAgentName("greeter"), SNAPSHOT, {
        kind: "record",
        fields: { name: { kind: "integer", value: 7 } },
      }).result,
    ).rejects.toThrow(/greeter.*input schema/);
  });

  test("the panic is catchable by a handle around the call_agent call site", async () => {
    // main: handle { call_agent(greeter, {}) } with panic(e) => break -1
    const ir = fixture();
    ir.blocks[6] = {
      block: {
        kind: "handle",
        parallel: false,
        initialStates: [],
        body: 7,
        handlers: [{ request: createAgentName("prelude.panic"), body: 8 }],
        thenClause: null,
      },
      parameters: {},
    };
    ir.blocks[7] = {
      block: {
        kind: "sequence",
        result: 74,
        operations: [
          { kind: "loadAgent", output: 71, name: createAgentName("greeter") },
          { kind: "makeRecord", entries: [], output: 72 },
          {
            kind: "makeRecord",
            entries: [
              ["target", 71],
              ["args", 72],
            ],
            output: 73,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.ai.call_agent") },
            argument: 73,
            output: 74,
          },
        ],
      },
      parameters: {},
    };
    ir.blocks[8] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 81, value: { kind: "integer", value: -1 } },
          { kind: "exit", target: 6, value: 81 },
        ],
      },
      parameters: { parameter: 80 },
    };
    ir.blocks[1] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "call", target: 6, output: 15 },
          { kind: "exit", target: 0, value: 15 },
        ],
      },
      parameters: { parameter: 10 },
    };
    await expect(runMain(ir, null)).resolves.toEqual({ kind: "integer", value: -1 });
  });
});
