// The delegate acceptance surface: schema validation of every delegation's argument, and the
// `call_agent` unwrap (a delegate to `prelude.call_agent` re-targets, under the same delegation, the
// callable its argument carries — so the dynamically dispatched args hit the same validation). Driven
// through the actor over hand-built IR, like `engine-smoke.test.ts`.

import { createAgentName, type IRModule, type JSONSchema, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { McpCall, McpCompletion, McpTransport } from "../src/runtime/external/mcp-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type { BlobId, DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
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
              target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
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
        block: { kind: "primitive", name: "prelude.reflection.call_agent", input: 50 },
        parameters: { parameter: 50 },
      },
    },
    entries: {
      [createAgentName("main")]: { block: 0, private: false },
      [createAgentName("greeter")]: { block: 2, private: false },
      [createAgentName("prelude.reflection.call_agent")]: { block: 4, private: false },
    },
    names: {},
  };
}

// A file parameter's `$katari_ref` reference schema (`Katari.Schema.fileReferenceSchema`).
const FILE_SCHEMA: JSONSchema = {
  type: "object",
  properties: { $katari_ref: { type: "string" }, $katari_semantic_kind: { type: "string" } },
  required: ["$katari_ref"],
  additionalProperties: true,
};

// The callee `use_file(image: file) -> file { image }` — its input schema expects a FILE at `image`.
const USE_FILE_SCHEMA: SchemaInfo = {
  input: {
    type: "object",
    properties: { image: FILE_SCHEMA },
    required: ["image"],
    additionalProperties: true,
  },
  output: {},
  requests: [],
  genericBindings: {},
};

/** The `fixture()` scaffold with the callee retargeted to `use_file(image: file) -> image` — so a dynamic
 *  argument's `image` position expects a real file. */
function fileFixture(): IRModule {
  const ir = fixture();
  ir.blocks[2] = {
    block: { kind: "agent", body: 3, schema: USE_FILE_SCHEMA, description: "", defaults: {} },
    parameters: {},
  };
  ir.blocks[3] = {
    block: {
      kind: "sequence",
      result: 21,
      operations: [{ kind: "getField", source: 20, field: "image", output: 21 }],
    },
    parameters: { parameter: 20 },
  };
  return ir;
}

function actorFor(ir: IRModule, mcp?: McpTransport): ProjectActor {
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
    ...(mcp !== undefined ? { mcp } : {}),
    persistence: new InMemoryPersistence(),
  });
}

function runMain(ir: IRModule, argument: Value | null, mcp?: McpTransport): Promise<Value> {
  return actorFor(ir, mcp).startRun(createAgentName("main"), SNAPSHOT, argument).result;
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

  test("throws a typed `reflection.call_error` when the args do not conform to the target's input schema", async () => {
    // A dynamic dispatch fails as `throw[reflection.call_error]`; unhandled, the run's error carries the
    // payload serialized through the codec (so the quotes inside the message arrive JSON-escaped).
    await expect(runMain(fixture(), argsOf({ wrong: { kind: "string", value: "oops" } }))).rejects.toThrow(
      /throw: .*prelude\.reflection\.call_error.*greeter.*input schema.*missing required field/,
    );
  });

  test("panics when the args carry a wrongly-typed field", async () => {
    await expect(runMain(fixture(), argsOf({ name: { kind: "integer", value: 3 } }))).rejects.toThrow(
      /\$\.name/,
    );
  });

  test("a real file argument flows through call_agent to a target whose schema expects a file", async () => {
    // call_agent no longer revives: the wire codec already reads a `$katari_ref` into a real `file` at the
    // boundary (`jsonToValue`), so by the time an argument reaches the dispatch it IS a `file` value — not an
    // inert `{ $katari_ref }` record. `use_file` receives (and returns) that actual `file`, conforming to its
    // `file`-typed `image` parameter.
    const image: Value = { kind: "ref", semanticKind: "file", blobId: "blob-img" as BlobId };
    await expect(runMain(fileFixture(), argsOf({ image }))).resolves.toEqual({
      kind: "ref",
      semanticKind: "file",
      blobId: "blob-img",
    });
  });

  test("throws a typed `reflection.call_error` when the target is not a callable value", async () => {
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
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
            argument: 13,
            output: 14,
          },
          { kind: "exit", target: 0, value: 14 },
        ],
      },
      parameters: { parameter: 10 },
    };
    // The dynamic dispatch failed before anything ran — the same catchable `call_error` a schema
    // violation raises (resolved at the emit site, like every dynamic dispatch).
    await expect(runMain(ir, null)).rejects.toThrow(
      /throw: .*prelude\.reflection\.call_error.*not a callable value/,
    );
  });
});

describe("call-site generics on the delegate operation", () => {
  // agent pick[T](x: T) -> T  — input schema { x: $generic 7 }, bindings { T: 7 }.
  // main delegates to it BY NAME with the operation-stamped instantiation [T -> integer] (what the
  // compiler emits for an inferred call), so the acceptance surface validates x against integer.
  function genericFixture(argumentLiteral: { kind: "integer"; value: number } | { kind: "string"; value: string }): IRModule {
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
              { kind: "loadLiteral", output: 11, value: argumentLiteral },
              { kind: "makeRecord", entries: [["x", 11]], output: 12 },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("pick") },
                argument: 12,
                output: 13,
                generics: [["T", { kind: "type", schema: { type: "integer" } }]],
              },
              { kind: "exit", target: 0, value: 13 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "agent",
            body: 3,
            schema: {
              input: {
                type: "object",
                properties: { x: { $generic: 7 } },
                required: ["x"],
                additionalProperties: true,
              },
              output: { $generic: 7 },
              requests: [],
              genericBindings: { T: 7 },
            },
            description: "",
            defaults: {},
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 21,
            operations: [{ kind: "getField", source: 20, field: "x", output: 21 }],
          },
          parameters: { parameter: 20 },
        },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("pick")]: { block: 2, private: false },
      },
      names: {},
    };
  }

  test("fills the callee's $generic input schema and accepts a conforming argument", async () => {
    await expect(runMain(genericFixture({ kind: "integer", value: 7 }), null)).resolves.toEqual({
      kind: "integer",
      value: 7,
    });
  });

  test("rejects an argument violating the instantiated schema (a defensive acceptance PANIC)", async () => {
    // This is a DIRECT delegate by name (not `call_agent`): the type checker guarantees a direct call site
    // conforms, so the runtime adds no pre-check for it. This synthetic IR bypasses that guarantee, so the
    // mismatch reaches the acceptance surface — the last-line defence — as a PANIC (a genuine defect / type
    // hole), not a `call_error`. (A DYNAMIC `call_agent` mismatch, by contrast, is a catchable `call_error`,
    // pinned above — that path pre-validates in the engine.)
    await expect(runMain(genericFixture({ kind: "string", value: "seven" }), null)).rejects.toThrow(
      /panic.*pick.*\$\.x: expected a value of type integer/,
    );
  });
});

describe("call_agent generic resolution — the target's own generics validate its input", () => {
  // agent transform[R](x: R) -> R { x }   — its OWN param is named `R`, colliding with call_agent[R,E]'s.
  // main instantiates the target's R to `integer` (on the value, via applyGenerics), then delegates through
  // call_agent whose OWN `R` is stamped as `string` on the operation. call_agent's `R` parameterises
  // call_agent's result, NOT the target's input — so the target's input must be validated at `integer`
  // (the value's carried generic), never rebound to call_agent's `string`. Both the engine pre-check and the
  // acceptance surface must resolve the input from that ONE source, or a valid arg would panic uncatchably.
  function transformFixture(): IRModule {
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
              { kind: "loadAgent", output: 12, name: createAgentName("transform") },
              {
                kind: "applyGenerics",
                source: 12,
                generics: [["R", { kind: "type", schema: { type: "integer" } }]],
                output: 13,
              },
              {
                kind: "makeRecord",
                entries: [
                  ["target", 13],
                  ["args", 11],
                ],
                output: 14,
              },
              {
                kind: "delegate",
                target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
                argument: 14,
                output: 15,
                // call_agent's OWN `R`, inferred as `string` — must NOT leak into the target's input.
                generics: [["R", { kind: "type", schema: { type: "string" } }]],
              },
              { kind: "exit", target: 0, value: 15 },
            ],
          },
          parameters: { parameter: 10 },
        },
        2: {
          block: {
            kind: "agent",
            body: 3,
            schema: {
              input: {
                type: "object",
                properties: { x: { $generic: 7 } },
                required: ["x"],
                additionalProperties: true,
              },
              output: { $generic: 7 },
              requests: [],
              genericBindings: { R: 7 },
            },
            description: "",
            defaults: {},
          },
          parameters: {},
        },
        3: {
          block: {
            kind: "sequence",
            result: 21,
            operations: [{ kind: "getField", source: 20, field: "x", output: 21 }],
          },
          parameters: { parameter: 20 },
        },
        4: {
          block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
          parameters: {},
        },
        5: {
          block: { kind: "primitive", name: "prelude.reflection.call_agent", input: 50 },
          parameters: { parameter: 50 },
        },
      },
      entries: {
        [createAgentName("main")]: { block: 0, private: false },
        [createAgentName("transform")]: { block: 2, private: false },
        [createAgentName("prelude.reflection.call_agent")]: { block: 4, private: false },
      },
      names: {},
    };
  }

  test("an arg valid at the TARGET's R runs — call_agent's own R does not rebind the target's input", async () => {
    // `x = 42` conforms to the target's R (= integer). It must run and return 42, NOT be validated against
    // call_agent's R (= string) and panic — the regression this fix prevents.
    await expect(
      runMain(transformFixture(), argsOf({ x: { kind: "integer", value: 42 } })),
    ).resolves.toEqual({ kind: "integer", value: 42 });
  });

  test("an arg violating the TARGET's R is a catchable call_error, not a panic", async () => {
    // `x = "hello"` violates the target's R (= integer): the engine pre-check catches it as a catchable
    // `reflection.call_error` (unhandled here, it fails the run), never reaching the acceptance-surface panic.
    const failure = runMain(transformFixture(), argsOf({ x: { kind: "string", value: "hello" } }));
    await expect(failure).rejects.toThrow(/reflection\.call_error.*transform.*input schema/);
    await expect(failure).rejects.not.toThrow(/panic/);
  });
});

describe("tool dispatch (reactor-backed tool agents)", () => {
  // A tool's attached input schema — what the emit-site dispatch validates the caller's args against.
  const TOOL_INPUT_SCHEMA: JSONSchema = {
    type: "object",
    properties: { name: { type: "string" } },
    required: ["name"],
    additionalProperties: false,
  };

  /** The server descriptor the tool carries as its reactor context (a `headers`-variant auth sum
   *  with a private header value — the reveal at the transport boundary is asserted below). A BARE
   *  descriptor, not the `{ descriptor, scope }` record `prelude.mcp.provide` mints: the reactor
   *  falls back to treating the whole context as the descriptor and skips the scope check, which is
   *  exactly the hand-built-tool path this suite pins. */
  function descriptor(): Value {
    return {
      kind: "record",
      fields: {
        url: { kind: "string", value: "https://mcp.example.test/mcp" },
        auth: {
          kind: "record",
          ctor: createAgentName("prelude.mcp.headers"),
          fields: {
            values: {
              kind: "record",
              fields: { authorization: { kind: "string", value: "sk-mcp", private: true } },
            },
          },
        },
      },
    };
  }

  function toolValue(): Value {
    return {
      kind: "tool",
      reactor: "mcp",
      name: "greet_tool",
      description: "greets, via a runtime-decided schema",
      context: descriptor(),
      snapshot: SNAPSHOT,
      inputSchema: TOOL_INPUT_SCHEMA,
    };
  }

  /** A transport the test drives by hand: dispatched tool calls are recorded, completions fed back. */
  class ControlledMcpTransport implements McpTransport {
    readonly dispatched: McpCall[] = [];
    private sink: ((completion: McpCompletion) => void) | null = null;
    onComplete(sink: (completion: McpCompletion) => void): void {
      this.sink = sink;
    }
    dispatch(call: McpCall): void {
      this.dispatched.push(call);
    }
    recover(): void {}
    abort(delegation: DelegationId): void {
      this.sink?.({ delegation, outcome: { kind: "cancelled" } });
    }
    evict(): void {
      // The reactor evicts a descriptor's cached client when the last provide scope on it closes; a
      // hand-driven transport holds nothing to evict.
    }
    close(): void {}
    feed(completion: McpCompletion): void {
      if (this.sink === null) throw new Error("no sink registered");
      this.sink(completion);
    }
  }

  /**
   * main receives { tool, args } and dispatches the tool — through `call_agent` or (the `direct`
   * variant) by delegating the tool VALUE itself. Either way the emit site validates args against the
   * tool's schema and the delegate goes STRAIGHT to the mcp reactor (no wrapper hop): the argument
   * verbatim, the descriptor riding the target as its context.
   */
  function toolFixture(direct: boolean): IRModule {
    const dispatchOperations = direct
      ? [
          { kind: "getField", source: 10, field: "tool", output: 11 },
          { kind: "getField", source: 10, field: "args", output: 12 },
          { kind: "delegate", target: { kind: "value", variable: 11 }, argument: 12, output: 13 },
          { kind: "exit", target: 0, value: 13 },
        ]
      : [
          { kind: "getField", source: 10, field: "tool", output: 11 },
          { kind: "getField", source: 10, field: "args", output: 12 },
          {
            kind: "makeRecord",
            entries: [
              ["target", 11],
              ["args", 12],
            ],
            output: 13,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
            argument: 13,
            output: 14,
          },
          { kind: "exit", target: 0, value: 14 },
        ];
    return {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: {
          block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} },
          parameters: {},
        },
        1: {
          block: { kind: "sequence", result: null, operations: dispatchOperations },
          parameters: { parameter: 10 },
        },
      },
      entries: { [createAgentName("main")]: { block: 0, private: false } },
      names: {},
    } as IRModule;
  }

  function toolArgument(args: Value): Value {
    return { kind: "record", fields: { tool: toolValue(), args } };
  }

  const CONFORMING: Value = {
    kind: "record",
    fields: { name: { kind: "string", value: "alice" } },
  };
  const VIOLATING: Value = { kind: "record", fields: { wrong: { kind: "integer", value: 1 } } };

  async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
    for (let attempt = 0; attempt < 1000; attempt++) {
      const value = predicate();
      if (value !== undefined) return value;
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
    throw new Error("waitUntil: predicate never held");
  }

  async function expectDirectDispatch(direct: boolean): Promise<void> {
    const transport = new ControlledMcpTransport();
    const result = runMain(toolFixture(direct), toolArgument(CONFORMING), transport);
    // The delegate reached the mcp reactor directly: a `callTool` dispatch naming the tool, the
    // caller's args verbatim, and the tool's descriptor with its secret header REVEALED at this (and
    // only this) boundary.
    const call = await waitUntil(() => transport.dispatched[0]);
    if (call.kind !== "callTool") throw new Error("expected a callTool dispatch");
    expect(call.tool).toBe("greet_tool");
    expect(call.argument).toEqual({ name: "alice" });
    expect(call.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: {
        $katari_constructor: "prelude.mcp.headers",
        $katari_value: { values: { authorization: "sk-mcp" } },
      },
    });
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: "hi alice" } });
    await expect(result).resolves.toEqual({ kind: "string", value: "hi alice" });
  }

  test("call_agent on a tool validates, then delegates straight to the tool's reactor", async () => {
    await expectDirectDispatch(false);
  });

  test("delegating a tool VALUE directly behaves exactly like the call_agent form", async () => {
    await expectDirectDispatch(true);
  });

  test("call_agent on a tool throws `reflection.call_error` naming the tool on a schema violation", async () => {
    await expect(runMain(toolFixture(false), toolArgument(VIOLATING))).rejects.toThrow(
      /throw: .*prelude\.reflection\.call_error.*greet_tool.*input schema/,
    );
  });

  test("a direct tool delegation still validates (and fails) against the tool's schema", async () => {
    await expect(runMain(toolFixture(true), toolArgument(VIOLATING))).rejects.toThrow(
      /throw: .*prelude\.reflection\.call_error.*greet_tool.*input schema/,
    );
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

  test("the run-start API rejects a malformed entry argument before starting the run (400)", async () => {
    // The run-start API is an external input boundary: `conformRunArgument` is what the facade calls to
    // reject a malformed argument as a 400 BEFORE the run starts. A conforming argument passes (null); a
    // violating one yields the schema-mismatch message the facade turns into the 400 body.
    const actor = actorFor(fixture());
    await expect(
      actor.conformRunArgument(createAgentName("greeter"), SNAPSHOT, {
        kind: "record",
        fields: { name: { kind: "string", value: "bob" } },
      }),
    ).resolves.toBeNull();
    await expect(
      actor.conformRunArgument(createAgentName("greeter"), SNAPSHOT, {
        kind: "record",
        fields: { name: { kind: "integer", value: 7 } },
      }),
    ).resolves.toMatch(/name: expected a value of type string/);
  });

  test("the run-start API refuses to start a private agent (400), even with a conforming argument", async () => {
    // A private agent is handle-private: startable only from within a private world, never from the
    // runtime's operator boundary. `conformRunArgument` refuses it up front (a self-contained rejection
    // the facade turns into a 400) — before argument validation, so even a conforming argument is
    // rejected — while a public entry in the same module still passes (null).
    const ir = fixture();
    ir.entries[createAgentName("greeter")] = { block: 2, private: true };
    const actor = actorFor(ir);
    await expect(
      actor.conformRunArgument(createAgentName("greeter"), SNAPSHOT, {
        kind: "record",
        fields: { name: { kind: "string", value: "bob" } },
      }),
    ).resolves.toMatch(/private and cannot be started from the runtime boundary/);
    await expect(
      actor.conformRunArgument(createAgentName("main"), SNAPSHOT, null),
    ).resolves.toBeNull();
  });

  test("a malformed argument on a static sub-call panics at the acceptance surface (last-line defence)", async () => {
    // A statically-typed direct `delegate` to `greeter` with a wrongly-typed `name` — the mismatch reaches
    // the acceptance surface's last-line defence, a PANIC (not a `call_error`: injecting a throw the callee's
    // row does not declare would be unsound; a panic is orthogonal to the row). The panic is raised at the
    // MORTAL caller (`main`), so it fails the run gracefully. (A malformed RUN ENTRY argument is instead
    // rejected at the run-start boundary — `conformRunArgument` above — never reaching this surface.)
    const ir = fixture();
    ir.blocks[1] = {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 30, value: { kind: "integer", value: 7 } },
          { kind: "makeRecord", entries: [["name", 30]], output: 31 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("greeter") },
            argument: 31,
            output: 32,
          },
          { kind: "exit", target: 0, value: 32 },
        ],
      },
      parameters: { parameter: 10 },
    };
    await expect(runMain(ir, null)).rejects.toThrow(/panic.*greeter.*input schema/);
  });

  test("the call_error is catchable by a throw handle around the call_agent call site", async () => {
    // main: handle { call_agent(greeter, {}) } with throw(e) => break -1
    const ir = fixture();
    ir.blocks[6] = {
      block: {
        kind: "handle",
        parallel: false,
        initialStates: [],
        body: 7,
        handlers: [{ request: createAgentName("prelude.throw"), body: 8 }],
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
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
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
