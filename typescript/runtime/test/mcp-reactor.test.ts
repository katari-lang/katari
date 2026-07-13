// End-to-end tests for the built-in `mcp` reactor, driven through the whole ProjectActor (no real MCP
// server — a controlled transport). Three call shapes are covered: `prelude.mcp.provide` (the SCOPED
// provider — the reactor lists the server under an internal side delegation, MINTS one agent value per
// listed tool carrying `{ descriptor, scope }` as its context, and dispatches the continuation with the
// toolbox; the whole call settles with the continuation's outcome, and settling closes the scope), a
// minted tool's call (an external delegate straight back to the reactor: the caller's args verbatim, the
// descriptor + scope riding the tool's context — a closed scope is rejected typed, the covariance
// backstop), and `prelude.mcp.call` (the static direct call: `{url, auth, tool, arguments}` all in the
// argument, gated on a LIVE provide scope of the same descriptor, the `arguments` json TREE lowered to
// the literal document for the transport, and the reply DECODED against the call's `T` generic — a typed
// `T` reconstructs the value wire form, `json.json` keeps the raw tree). Failures are typed
// `throw[mcp.server_error]` (a reply that does not conform to `T` is `throw[json.decode_error]`);
// recovery of an in-flight tool call is at-most-once (an interrupted call fails typed — a katari retry
// reconnects through the transport's descriptor cache), while the provide endpoint itself survives a
// restart.

import {
  createAgentName,
  type GenericArgumentSchema,
  type IRModule,
  type JSONSchema,
  type QualifiedName,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type {
  McpCall,
  McpCompletion,
  McpTransport,
} from "../src/runtime/external/mcp-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { BlobId, DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-mcp" as ProjectId;
const SNAPSHOT = "snapshot-mcp" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

// agent main() {
//   mcp.provide(url = "https://mcp.example.test/mcp",
//               auth = mcp.headers(values = { authorization: "sk-mcp" }),
//               continuation = continuation)
// }
// agent continuation(value) {   // dispatched with { value: toolbox } once the listing lands
//   let toolbox = value.value
//   return reflection.call_agent(target = toolbox.add, args = { x: 19, y: 23 })
// }
const PROVIDE_IR: IRModule = {
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
          {
            kind: "loadLiteral",
            output: 11,
            value: { kind: "string", value: "https://mcp.example.test/mcp" },
          },
          { kind: "loadLiteral", output: 12, value: { kind: "string", value: "sk-mcp" } },
          { kind: "makeRecord", entries: [["authorization", 12]], output: 13 },
          { kind: "makeRecord", entries: [["values", 13]], output: 14 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 14,
            output: 15,
          },
          { kind: "loadAgent", output: 16, name: createAgentName("continuation") },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 15],
              ["continuation", 16],
            ],
            output: 17,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.provide") },
            argument: 17,
            output: 18,
          },
          { kind: "exit", target: 0, value: 18 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.provide", input: 30, reactor: "mcp" },
      parameters: { parameter: 30 },
    },
    4: {
      block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    5: {
      block: { kind: "construct", name: createAgentName("prelude.mcp.headers"), input: 50 },
      parameters: { parameter: 50 },
    },
    // continuation: receives { value: toolbox } and calls the minted `add` through call_agent.
    6: {
      block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    7: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "getField", source: 60, field: "value", output: 61 },
          { kind: "getField", source: 61, field: "add", output: 62 },
          { kind: "loadLiteral", output: 63, value: { kind: "integer", value: 19 } },
          { kind: "loadLiteral", output: 64, value: { kind: "integer", value: 23 } },
          {
            kind: "makeRecord",
            entries: [
              ["x", 63],
              ["y", 64],
            ],
            output: 65,
          },
          {
            kind: "makeRecord",
            entries: [
              ["target", 62],
              ["args", 65],
            ],
            output: 66,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
            argument: 66,
            output: 67,
          },
          { kind: "exit", target: 6, value: 67 },
        ],
      },
      parameters: { parameter: 60 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.provide")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
    [createAgentName("continuation")]: 6,
  },
  names: {},
};

// The covariance-hole probe: the continuation RETURNS the minted tool, so the provide settles with the
// tool as its result — the scope is already closed by the time main calls it.
// agent main() {
//   let tool = mcp.provide(url = "https://mcp.example.test/mcp",
//                          auth = mcp.headers(values = {}), continuation = pick_add)
//   tool(x = 1, y = 2)   // the scope closed when the provide settled — must fail typed
// }
// agent pick_add(value) { value.value.add }
const ESCAPED_TOOL_IR: IRModule = {
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
          {
            kind: "loadLiteral",
            output: 11,
            value: { kind: "string", value: "https://mcp.example.test/mcp" },
          },
          { kind: "makeRecord", entries: [], output: 12 },
          { kind: "makeRecord", entries: [["values", 12]], output: 13 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 13,
            output: 14,
          },
          { kind: "loadAgent", output: 15, name: createAgentName("pick_add") },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 14],
              ["continuation", 15],
            ],
            output: 16,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.provide") },
            argument: 16,
            output: 17,
          },
          { kind: "loadLiteral", output: 18, value: { kind: "integer", value: 1 } },
          { kind: "loadLiteral", output: 19, value: { kind: "integer", value: 2 } },
          {
            kind: "makeRecord",
            entries: [
              ["x", 18],
              ["y", 19],
            ],
            output: 20,
          },
          { kind: "delegate", target: { kind: "value", variable: 17 }, argument: 20, output: 21 },
          { kind: "exit", target: 0, value: 21 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.provide", input: 30, reactor: "mcp" },
      parameters: { parameter: 30 },
    },
    4: {
      block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    5: {
      block: { kind: "construct", name: createAgentName("prelude.mcp.headers"), input: 50 },
      parameters: { parameter: 50 },
    },
    // pick_add: leaks the minted `add` tool out of its scope by returning it.
    6: {
      block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    7: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "getField", source: 60, field: "value", output: 61 },
          { kind: "getField", source: 61, field: "add", output: 62 },
          { kind: "exit", target: 6, value: 62 },
        ],
      },
      parameters: { parameter: 60 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.provide")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
    [createAgentName("pick_add")]: 6,
  },
  names: {},
};

/** The listing completion the controlled transport feeds for a provide's `listTools`. */
const ADD_LISTING: McpCompletion["outcome"] = {
  kind: "result",
  value: {
    tools: [
      {
        name: "add",
        description: "Adds two integers.",
        inputSchema: {
          type: "object",
          properties: { x: { type: "number" }, y: { type: "number" } },
          required: ["x", "y"],
        },
        outputSchema: { type: "string" },
      },
    ],
  },
};

/** A transport the test drives by hand (mirrors `ControlledHttpTransport`): dispatches are recorded,
 *  completions are fed by the test, and a recovery refuses with the typed restart throw. */
class ControlledMcpTransport implements McpTransport {
  readonly dispatched: McpCall[] = [];
  readonly recovered: DelegationId[] = [];
  private sink: ((completion: McpCompletion) => void) | null = null;

  onComplete(sink: (completion: McpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: McpCall): void {
    this.dispatched.push(call);
  }

  recover(delegation: DelegationId): void {
    this.recovered.push(delegation);
    // A fresh test transport holds no live work; recovery refuses with the typed throw the real
    // transport reports (a katari retry then reconnects through the descriptor cache).
    this.feed({
      delegation,
      outcome: {
        kind: "throw",
        error: {
          $constructor: "prelude.mcp.server_error",
          value: { message: "mcp call interrupted by a runtime restart" },
        },
      },
    });
  }

  abort(delegation: DelegationId): void {
    this.feed({ delegation, outcome: { kind: "cancelled" } });
  }

  evict(): void {
    // The reactor evicts a descriptor's cached client when the last provide scope on it closes; a
    // hand-driven transport holds nothing to evict.
  }

  close(): void {
    this.sink = null;
  }

  feed(completion: McpCompletion): void {
    if (this.sink === null) throw new Error("ControlledMcpTransport: no sink registered");
    this.sink(completion);
  }
}

/** `PROVIDE_IR` with the continuation TYPED: output `{ done: boolean }` (closed), returning
 *  `{ done: true }` AFTER the mid-body tool call — the reviewer's regression shape. The tool's
 *  intermediate result is bound and unused; only the value the continuation RETURNS must meet its own
 *  output schema, so the mid-body ack must not be conformed against it (a `dispatched` proxy is not the
 *  `wrapper` hop whose ack IS the instance's result). */
function typedContinuationIr(base: IRModule): IRModule {
  const clone: IRModule = structuredClone(base);
  const continuationAgent = clone.blocks[6]?.block;
  if (continuationAgent?.kind !== "agent") {
    throw new Error("block 6 must be the continuation agent");
  }
  continuationAgent.schema = {
    input: {},
    output: {
      type: "object",
      properties: { done: { type: "boolean" } },
      required: ["done"],
      additionalProperties: false,
    },
    requests: [],
    genericBindings: {},
  };
  const body = clone.blocks[7]?.block;
  if (body?.kind !== "sequence") throw new Error("block 7 must be the continuation sequence");
  const exit = body.operations.pop();
  if (exit?.kind !== "exit") throw new Error("the continuation must end with an exit");
  body.operations.push(
    { kind: "loadLiteral", output: 68, value: { kind: "boolean", value: true } },
    { kind: "makeRecord", entries: [["done", 68]], output: 69 },
    { kind: "exit", target: 6, value: 69 },
  );
  return clone;
}

function makeActor(
  ir: IRModule,
  mcp: McpTransport,
  persistence: Persistence = new InMemoryPersistence(),
  blobs: InMemoryBlobStore = new InMemoryBlobStore(),
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(ir.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), ir);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs,
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    mcp,
    persistence,
  });
}

async function waitUntil<T>(predicate: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 1000; attempt++) {
    const value = predicate();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  throw new Error("waitUntil: predicate never held");
}

describe("mcp reactor", () => {
  test("provide lists the server, mints the toolbox for its continuation, and a minted tool's call goes straight back to the reactor", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(PROVIDE_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // 1. The provide's listing: a `listTools` dispatch (under an internal side delegation — its
    //    completion never settles the provide) carrying the descriptor read from the argument — the
    //    auth sum rides inside it as its `$constructor` wire form, headers revealed for the transport
    //    (an MCP server is an allowed sink).
    const listing = await waitUntil(() => transport.dispatched[0]);
    expect(listing.kind).toBe("listTools");
    expect(listing.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: {
        $constructor: "prelude.mcp.headers",
        value: { values: { authorization: "sk-mcp" } },
      },
    });
    transport.feed({ delegation: listing.delegation, outcome: ADD_LISTING });

    // 2. The minted tool's call, issued by the continuation the listing dispatched: a `callTool` by
    //    its server-declared name, the caller's args verbatim, the descriptor from the minted tool's
    //    `{ descriptor, scope }` context.
    const toolCall = await waitUntil(() => transport.dispatched[1]);
    if (toolCall.kind !== "callTool") throw new Error("expected a callTool dispatch");
    expect(toolCall.tool).toBe("add");
    expect(toolCall.argument).toEqual({ x: 19, y: 23 });
    expect(toolCall.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: {
        $constructor: "prelude.mcp.headers",
        value: { values: { authorization: "sk-mcp" } },
      },
    });
    // The continuation's outcome IS the provide's outcome — the run resolves with it.
    transport.feed({ delegation: toolCall.delegation, outcome: { kind: "result", value: "42" } });
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
  });

  test("a tool result carrying file handles lifts them into `file` values for the caller", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(PROVIDE_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const listing = await waitUntil(() => transport.dispatched[0]);
    transport.feed({ delegation: listing.delegation, outcome: ADD_LISTING });
    const toolCall = await waitUntil(() => transport.dispatched[1]);
    // What the SDK transport emits for an image-bearing result: the produced blob's slim `$ref`
    // handle riding in `{ text, files }` (see `resolveToolResult`; the producer registered
    // ownership, and the blob's metadata lives on its row — never on the handle).
    transport.feed({
      delegation: toolCall.delegation,
      outcome: {
        kind: "result",
        value: {
          text: "rendered a chart",
          files: [{ $ref: "blob-mcp-image", semanticKind: "file" }],
        },
      },
    });
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: {
        text: { kind: "string", value: "rendered a chart" },
        files: {
          kind: "array",
          elements: [{ kind: "ref", semanticKind: "file", blobId: "blob-mcp-image" }],
        },
      },
    });
  });

  test("a server-reported failure surfaces as a typed throw[mcp.server_error]", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(PROVIDE_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The failure is fed at the LISTING stage: a listing failure the continuation never saw settles
    // the whole provide with the typed throw.
    const listing = await waitUntil(() => transport.dispatched[0]);
    transport.feed({
      delegation: listing.delegation,
      outcome: {
        kind: "throw",
        error: { $constructor: "prelude.mcp.server_error", value: { message: "listing exploded" } },
      },
    });
    // Unhandled, the typed throw fails the run carrying the data payload (a handler would catch it).
    await expect(result).rejects.toThrow(/prelude\.mcp\.server_error.*listing exploded/);
  });

  test("an interrupted TOOL CALL recovers as the typed restart throw (at-most-once, never re-run)", async () => {
    const persistence = new StoringPersistence();
    const first = new ControlledMcpTransport();
    const actor = makeActor(PROVIDE_IR, first, persistence);
    const { run } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // Drive the provide to ACTIVE: feed the listing so the continuation dispatches, and leave its
    // minted tool's `callTool` in flight — the meaningful at-most-once case.
    const listing = await waitUntil(() => first.dispatched[0]);
    first.feed({ delegation: listing.delegation, outcome: ADD_LISTING });
    await waitUntil(() => first.dispatched[1]);

    // Restart: a fresh actor over the same rows. The provide scope re-registers (its continuation was
    // consumed at dispatch and resumes as durable core work — no re-list), but the in-flight tool call
    // is recovered, not re-run; the transport refuses with the typed throw, and the run's durable
    // outcome records the error.
    const second = new ControlledMcpTransport();
    const reloaded = makeActor(PROVIDE_IR, second, persistence);
    await reloaded.activate();
    await waitUntil(() => second.recovered[0]);
    await waitUntil(() => (persistence.peekRun(run)?.state === "error" ? true : undefined));
    expect(persistence.peekRun(run)?.errorMessage).toContain("interrupted by a runtime restart");
    // Nothing was re-dispatched: no fresh listing (the provide is past it) and no re-run tool call.
    expect(second.dispatched).toHaveLength(0);
  });

  test("a minted tool called after its provide scope closed is rejected typed (the covariance backstop)", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(ESCAPED_TOOL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The continuation returns the minted `add` itself, so the provide settles with the tool as its
    // result and the scope closes; main then calls the escaped tool.
    const listing = await waitUntil(() => transport.dispatched[0]);
    expect(listing.kind).toBe("listTools");
    transport.feed({ delegation: listing.delegation, outcome: ADD_LISTING });
    await expect(result).rejects.toThrow(/prelude\.mcp\.server_error.*has closed/);
    // The rejection happened at the reactor's scope check — the listing stays the transport's only
    // dispatch; no `callTool` ever reached it.
    expect(transport.dispatched).toHaveLength(1);
  });

  test("a TYPED caller's mid-body tool call is not conformed against the caller's own output schema", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(typedContinuationIr(PROVIDE_IR), transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const listing = await waitUntil(() => transport.dispatched[0]);
    transport.feed({ delegation: listing.delegation, outcome: ADD_LISTING });
    const toolCall = await waitUntil(() => transport.dispatched[1]);
    // The tool's intermediate result ("42", a string) plainly violates the continuation's own
    // `{ done: boolean }` output schema — and must not be checked against it mid-body: the caller's
    // schema binds the value the caller RETURNS, which the engine still conforms below.
    transport.feed({ delegation: toolCall.delegation, outcome: { kind: "result", value: "42" } });
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: { done: { kind: "boolean", value: true } },
    });
  });
});

// One shape of the `json` union's emitted schema (`Katari.Schema`): a `data` value nests its fields under
// `value`, keyed by a `$constructor` const. `json.json` itself is the seven-shape anyOf below.
function jsonShape(constructorName: string, valueProperties: Record<string, JSONSchema>): JSONSchema {
  return {
    type: "object",
    properties: {
      $constructor: { const: constructorName },
      value: {
        type: "object",
        properties: valueProperties,
        required: Object.keys(valueProperties),
        additionalProperties: true,
      },
    },
    required: ["$constructor", "value"],
    additionalProperties: false,
  };
}

// The `json.json` output schema the codegen stamps on `mcp.call[..., json.json]`: the seven-shape anyOf
// of the `json` union, mirroring what the compiler emits for `json.json`. A reply lifted as a LITERAL
// `json` tree conforms to it, so the direct call keeps the raw tree (with its inert `$ref` objects) — the
// no-`outputSchema` behaviour. A NON-tree value (a bare record, a scalar) does NOT conform, so a typed
// `T` instead reconstructs the value wire form. (A nested `json` position expands to `{}` here — enough
// for the decode's "is this a json tree?" question; the real schema breaks its own recursion the same way.)
const JSON_TREE_SCHEMA: JSONSchema = {
  anyOf: [
    jsonShape("prelude.json.json_null", {}),
    jsonShape("prelude.json.json_boolean", { value: { type: "boolean" } }),
    jsonShape("prelude.json.json_integer", { value: { type: "integer" } }),
    jsonShape("prelude.json.json_number", { value: { type: "number" } }),
    jsonShape("prelude.json.json_string", { value: { type: "string" } }),
    jsonShape("prelude.json.json_array", { items: { type: "array", items: {} } }),
    jsonShape("prelude.json.json_object", { entries: { type: "object", additionalProperties: {} } }),
  ],
};

// A `file` value's `$ref` handle schema (`Katari.Schema.fileReferenceSchema`): a typed `T` that carries a
// file reconstructs a REAL handle from the reply's `$ref` object, so its lifetime rides the value walk.
const FILE_REF_SCHEMA: JSONSchema = {
  type: "object",
  properties: { $ref: { type: "string" }, semanticKind: { type: "string" } },
  required: ["$ref"],
  additionalProperties: true,
};

/** The delegate generics a `mcp.call[url, T]` stamps: only `T` matters to the reactor's reply decode (the
 *  literal `URL` gates the scope, not the shape). The engine forwards the external agent's own ambient to
 *  the reactor, so `generics.T` reaches the direct call the same way a compiled `mcp.call[url, T]` does. */
function directCallGenerics(outputSchema: JSONSchema): Array<[string, GenericArgumentSchema]> {
  return [["T", { kind: "type", schema: outputSchema }]];
}

// agent main() {
//   mcp.provide(url = "https://mcp.example.test/mcp", auth = mcp.headers(values = {}),
//               continuation = call_runner)
// }
// agent call_runner(value) {   // the direct call must run INSIDE a provide of the same descriptor
//   let arguments = json.json_object(entries = { x = json.json_integer(value = 19),
//                                                note = json.json_string(value = "hi") })
//   // T = json.json: the reply comes back as a raw `json` tree (the codegen's no-outputSchema choice).
//   return mcp.call["https://mcp.example.test/mcp", json.json](url = "https://mcp.example.test/mcp",
//                   auth = mcp.headers(values = {}), tool = "add", arguments = arguments)
// }
const CALL_IR: IRModule = {
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
          {
            kind: "loadLiteral",
            output: 11,
            value: { kind: "string", value: "https://mcp.example.test/mcp" },
          },
          { kind: "makeRecord", entries: [], output: 12 },
          { kind: "makeRecord", entries: [["values", 12]], output: 13 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 13,
            output: 14,
          },
          { kind: "loadAgent", output: 15, name: createAgentName("call_runner") },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 14],
              ["continuation", 15],
            ],
            output: 16,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.provide") },
            argument: 16,
            output: 17,
          },
          { kind: "exit", target: 0, value: 17 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.call", input: 30, reactor: "mcp" },
      parameters: { parameter: 30 },
    },
    4: {
      block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    5: {
      block: { kind: "construct", name: createAgentName("prelude.mcp.headers"), input: 50 },
      parameters: { parameter: 50 },
    },
    6: {
      block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    7: {
      block: { kind: "construct", name: createAgentName("prelude.json.json_integer"), input: 70 },
      parameters: { parameter: 70 },
    },
    8: {
      block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    9: {
      block: { kind: "construct", name: createAgentName("prelude.json.json_string"), input: 90 },
      parameters: { parameter: 90 },
    },
    20: {
      block: { kind: "agent", body: 21, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    21: {
      block: { kind: "construct", name: createAgentName("prelude.json.json_object"), input: 210 },
      parameters: { parameter: 210 },
    },
    22: {
      block: { kind: "agent", body: 23, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    23: {
      block: { kind: "external", key: "prelude.mcp.provide", input: 230, reactor: "mcp" },
      parameters: { parameter: 230 },
    },
    // call_runner: builds the json tree and performs the direct call inside the provide scope.
    24: {
      block: { kind: "agent", body: 25, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    25: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          {
            kind: "loadLiteral",
            output: 101,
            value: { kind: "string", value: "https://mcp.example.test/mcp" },
          },
          { kind: "makeRecord", entries: [], output: 102 },
          { kind: "makeRecord", entries: [["values", 102]], output: 103 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 103,
            output: 104,
          },
          { kind: "loadLiteral", output: 105, value: { kind: "integer", value: 19 } },
          { kind: "makeRecord", entries: [["value", 105]], output: 106 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_integer") },
            argument: 106,
            output: 107,
          },
          { kind: "loadLiteral", output: 108, value: { kind: "string", value: "hi" } },
          { kind: "makeRecord", entries: [["value", 108]], output: 109 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_string") },
            argument: 109,
            output: 110,
          },
          {
            kind: "makeRecord",
            entries: [
              ["x", 107],
              ["note", 110],
            ],
            output: 111,
          },
          { kind: "makeRecord", entries: [["entries", 111]], output: 112 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_object") },
            argument: 112,
            output: 113,
          },
          { kind: "loadLiteral", output: 114, value: { kind: "string", value: "add" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 101],
              ["auth", 104],
              ["tool", 114],
              ["arguments", 113],
            ],
            output: 115,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.call") },
            argument: 115,
            output: 116,
            // `mcp.call[url, json.json]` — the codegen's no-`outputSchema` instantiation. The engine
            // forwards this to the mcp reactor as the external agent's ambient, so the reply is decoded
            // against `json.json` (kept as the raw tree).
            generics: directCallGenerics(JSON_TREE_SCHEMA),
          },
          { kind: "exit", target: 24, value: 116 },
        ],
      },
      parameters: { parameter: 100 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.call")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
    [createAgentName("prelude.json.json_integer")]: 6,
    [createAgentName("prelude.json.json_string")]: 8,
    [createAgentName("prelude.json.json_object")]: 20,
    [createAgentName("prelude.mcp.provide")]: 22,
    [createAgentName("call_runner")]: 24,
  },
  names: {},
};

// agent main() { mcp.call["...", json.json](url = ..., auth = mcp.headers(values = {}), tool = "add") }
// — NO provide anywhere, so the reactor must reject the direct call before any transport dispatch (the
// scope gate fires ahead of any reply decode, so this IR carries no `T` generic).
const UNSCOPED_CALL_IR: IRModule = {
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
          {
            kind: "loadLiteral",
            output: 11,
            value: { kind: "string", value: "https://mcp.example.test/mcp" },
          },
          { kind: "makeRecord", entries: [], output: 12 },
          { kind: "makeRecord", entries: [["values", 12]], output: 13 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 13,
            output: 14,
          },
          { kind: "loadLiteral", output: 15, value: { kind: "string", value: "add" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 14],
              ["tool", 15],
            ],
            output: 16,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.call") },
            argument: 16,
            output: 17,
          },
          { kind: "exit", target: 0, value: 17 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.call", input: 30, reactor: "mcp" },
      parameters: { parameter: 30 },
    },
    4: {
      block: { kind: "agent", body: 5, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    5: {
      block: { kind: "construct", name: createAgentName("prelude.mcp.headers"), input: 50 },
      parameters: { parameter: 50 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.call")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
  },
  names: {},
};

/** The `json` tree Value a scalar / object test asserts against — mirrors `engine/json-value.ts`. */
function jsonTree(ctor: string, fields: Record<string, Value>): Value {
  return { kind: "record", ctor: createAgentName(ctor), fields };
}
const treeString = (value: string): Value =>
  jsonTree("prelude.json.json_string", { value: { kind: "string", value } });
const treeInteger = (value: number): Value =>
  jsonTree("prelude.json.json_integer", { value: { kind: "integer", value } });
const treeObject = (entries: Record<string, Value>): Value =>
  jsonTree("prelude.json.json_object", { entries: { kind: "record", fields: entries } });
const treeArray = (elements: Value[]): Value =>
  jsonTree("prelude.json.json_array", { items: { kind: "array", elements } });

/** `CALL_IR` with the direct call's `T` re-stamped: the typed-decode variants reuse the whole provide +
 *  call_runner scaffold and only change what the reply is decoded against. */
function callIrWithT(outputSchema: JSONSchema): IRModule {
  const clone: IRModule = structuredClone(CALL_IR);
  const body = clone.blocks[25]?.block;
  if (body?.kind !== "sequence") {
    throw new Error("CALL_IR block 25 must be the call_runner sequence");
  }
  for (const operation of body.operations) {
    if (
      operation.kind === "delegate" &&
      operation.target.kind === "name" &&
      String(operation.target.name) === "prelude.mcp.call"
    ) {
      operation.generics = directCallGenerics(outputSchema);
    }
  }
  return clone;
}

/** Drive `CALL_IR`'s wrapping provide to active: the first dispatch is the provide's `listTools`; feed
 *  it an EMPTY listing so the continuation (`call_runner`) dispatches, and return the `callTool` its
 *  `mcp.call` then ships as `dispatched[1]`. */
async function callToolAfterProvide(transport: ControlledMcpTransport): Promise<McpCall> {
  const listing = await waitUntil(() => transport.dispatched[0]);
  if (listing.kind !== "listTools") throw new Error("expected the provide's listTools dispatch");
  transport.feed({
    delegation: listing.delegation,
    outcome: { kind: "result", value: { tools: [] } },
  });
  return waitUntil(() => transport.dispatched[1]);
}

describe("mcp reactor: the direct call (prelude.mcp.call)", () => {
  test("lowers the arguments TREE to the literal document and ships the same callTool operation", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    if (call.kind !== "callTool") throw new Error("expected a callTool dispatch");
    expect(call.tool).toBe("add");
    // The wire-form asymmetry contract: the transport receives the LITERAL document the tree denotes
    // — no `$constructor` tagging anywhere (that would be the value wire form, which a server does
    // not speak).
    expect(call.argument).toEqual({ x: 19, note: "hi" });
    expect(call.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: { $constructor: "prelude.mcp.headers", value: { values: {} } },
    });

    // `T = json.json` (CALL_IR's instantiation): the structured reply lifts LITERALLY into the `json`
    // tree the caller receives, since that tree conforms to the seven-shape `json` union.
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { sum: 42 } },
    });
    await expect(result).resolves.toEqual(treeObject({ sum: treeInteger(42) }));
  });

  test("T = json.json: a plain-text reply becomes a json_string tree", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: "just text" } });
    await expect(result).resolves.toEqual(treeString("just text"));
  });

  test("T = json.json: a blob-bearing reply keeps the `$ref` handle as a LITERAL object inside the tree", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: { text: "rendered", files: [{ $ref: "blob-mcp-image", semanticKind: "file" }] },
      },
    });
    // `T = json.json`: the handle is NOT lifted into a `file` value here (a typed `T` would do that);
    // it survives as the literal `$ref` object inside the tree, which a later `json.decode` reconstructs.
    await expect(result).resolves.toEqual(
      treeObject({
        text: treeString("rendered"),
        files: treeArray([
          treeObject({ $ref: treeString("blob-mcp-image"), semanticKind: treeString("file") }),
        ]),
      }),
    );
  });

  test("T = json.json: a produced blob left inert in the tree run-adopts (the narrowed backstop)", async () => {
    const transport = new ControlledMcpTransport();
    const blobs = new InMemoryBlobStore();
    const blob = "blob-mcp-direct" as BlobId;
    const bytes = new Uint8Array([1, 2, 3, 4]);
    await blobs.put(PROJECT, blob, bytes);
    const actor = makeActor(CALL_IR, transport, new InMemoryPersistence(), blobs);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // The transport produced a blob from a tool result's image content mid-call: register its ownership
    // (bytes already staged above), exactly as the SDK transport's blob bridge does — a REAL produced blob,
    // not just a `$ref` string. It targets the `callTool` delegation, the call the blob belongs to.
    const registered = await actor.registerProducedMcpBlob(call.delegation, blob, {
      hash: "hash",
      size: bytes.byteLength,
      semanticKind: "file",
    });
    expect(registered).toBe(true);

    // `T = json.json` keeps the raw tree, so the blob rides only as a `$ref` STRING leaf, not a real ref —
    // the value-driven resource ascent cannot carry it. This is the ONE case the run-adoption backstop
    // still exists for.
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: { text: "rendered", files: [{ $ref: blob, semanticKind: "file" }] },
      },
    });
    await expect(result).resolves.toEqual(
      treeObject({
        text: treeString("rendered"),
        files: treeArray([
          treeObject({ $ref: treeString(blob), semanticKind: treeString("file") }),
        ]),
      }),
    );

    // Still readable after the call settles: the produced blob was ADOPTED onto the (permanent) run
    // instance rather than reclaimed with the ephemeral call — the narrowed backstop for a `$ref` the
    // literal tree carries only as a string.
    await expect(blobs.get(PROJECT, blob)).resolves.toEqual(bytes);
  });

  test("a typed T decodes the reply to a real value (a record shape)", async () => {
    const transport = new ControlledMcpTransport();
    // T = { sum: integer } — a fully mapped outputSchema.
    const outputSchema: JSONSchema = {
      type: "object",
      properties: { sum: { type: "integer" } },
      required: ["sum"],
    };
    const actor = makeActor(callIrWithT(outputSchema), transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // The server's `structuredContent`, a plain document conforming to the outputSchema.
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: { sum: 42 } } });
    // Decoded against `T`: a REAL record value (not the `json` tree), validated to conform.
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: { sum: { kind: "integer", value: 42 } },
    });
  });

  test("a typed T carrying a file reconstructs a REAL handle that ascends by value (not run-adopted)", async () => {
    const transport = new ControlledMcpTransport();
    const blobs = new InMemoryBlobStore();
    const blob = "blob-mcp-typed" as BlobId;
    const bytes = new Uint8Array([9, 8, 7, 6]);
    await blobs.put(PROJECT, blob, bytes);
    // T = { text: string, files: array[file] } — the reply's `$ref` reconstructs a REAL file handle.
    const outputSchema: JSONSchema = {
      type: "object",
      properties: { text: { type: "string" }, files: { type: "array", items: FILE_REF_SCHEMA } },
      required: ["text", "files"],
    };
    const actor = makeActor(callIrWithT(outputSchema), transport, new InMemoryPersistence(), blobs);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    const registered = await actor.registerProducedMcpBlob(call.delegation, blob, {
      hash: "hash",
      size: bytes.byteLength,
      semanticKind: "file",
    });
    expect(registered).toBe(true);

    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: { text: "rendered", files: [{ $ref: blob, semanticKind: "file" }] },
      },
    });
    // The `$ref` reconstructs a REAL `ref` value — not the inert tree object of the `json.json` case — so
    // the file rides the ordinary release / reown walk. Its lifetime is now value-reachability: the
    // run-adoption backstop is a no-op here (the blob was released to in-transit by value, not left owned
    // by the ephemeral call), which is exactly "value-owned rather than run-adopted".
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: {
        text: { kind: "string", value: "rendered" },
        files: {
          kind: "array",
          elements: [{ kind: "ref", semanticKind: "file", blobId: blob }],
        },
      },
    });
    // The real handle survived to the caller via the value walk (still readable after settle).
    await expect(blobs.get(PROJECT, blob)).resolves.toEqual(bytes);
  });

  test("a reply that does not conform to a typed T throws json.decode_error", async () => {
    const transport = new ControlledMcpTransport();
    const outputSchema: JSONSchema = {
      type: "object",
      properties: { sum: { type: "integer" } },
      required: ["sum"],
    };
    const actor = makeActor(callIrWithT(outputSchema), transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // `sum` is a string, not an integer — the reply cannot take `T`'s shape.
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { sum: "not a number" } },
    });
    // The row declares `json.decode_error`; the runtime raises it (never a panic) so a handler catches it.
    await expect(result).rejects.toThrow(/prelude\.json\.decode_error.*does not conform to T/);
  });

  test("a plain-text reply decodes into a string-shaped T", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(callIrWithT({ type: "string" }), transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: "just text" } });
    // Decoded against `T = string`: the plain string VALUE (not a `json_string` tree node).
    await expect(result).resolves.toEqual({ kind: "string", value: "just text" });
  });

  test("a transport error surfaces as the typed throw[mcp.server_error]", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // The real transport reports every anticipated failure as this typed throw (never a bare `error`,
    // which the reactor now treats as an engine-invariant panic uniformly).
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "throw",
        error: {
          $constructor: "prelude.mcp.server_error",
          value: { message: "connection refused" },
        },
      },
    });
    await expect(result).rejects.toThrow(/prelude\.mcp\.server_error.*connection refused/);
  });

  test("a direct call with NO live provide scope is rejected typed, before any transport dispatch", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(UNSCOPED_CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // The reactor rejects at its scope gate — nothing to feed, and the transport never hears of it.
    await expect(result).rejects.toThrow(/prelude\.mcp\.server_error.*no live mcp\.provide scope/);
    expect(transport.dispatched).toHaveLength(0);
  });
});
