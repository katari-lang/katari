// End-to-end tests for the built-in `mcp` reactor, driven through the whole ProjectActor (no real MCP
// server — a controlled transport). Three call shapes are covered: `prelude.mcp.provide` (the SCOPED
// provider — the reactor lists the server under an internal side delegation, MINTS one agent value per
// listed tool carrying `{ descriptor, scope }` as its context, and dispatches the continuation with the
// toolbox; the whole call settles with the continuation's outcome, and settling closes the scope), a
// minted tool's call (an external delegate straight back to the reactor: the caller's args verbatim, the
// descriptor + scope riding the tool's context — a closed scope is rejected typed, the covariance
// backstop), and `prelude.mcp.call` (the static direct call: `{url, auth, tool, arguments}` all in the
// argument, gated on a LIVE provide scope of the same descriptor, the `arguments` json TREE lowered to
// the literal document for the transport, and the reply DECODED UNCONDITIONALLY — the wire's own
// `$katari_*` markers reconstruct the value at ANY `T` (a `$katari_ref` is always a real `file`), and the
// declared `T` only VALIDATES the result). Failures are typed
// `throw[mcp.server_error]` (a reply that does not conform to `T`, or one carrying a marker the wire
// cannot reconstruct, is `throw[json.validation_error]`);
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
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.mcp.provide")]: { block: 2, private: false },
    [createAgentName("prelude.mcp.headers")]: { block: 4, private: false },
    [createAgentName("continuation")]: { block: 6, private: false },
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
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.mcp.provide")]: { block: 2, private: false },
    [createAgentName("prelude.mcp.headers")]: { block: 4, private: false },
    [createAgentName("pick_add")]: { block: 6, private: false },
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
          $katari_constructor: "prelude.mcp.server_error",
          $katari_value: { message: "mcp call interrupted by a runtime restart" },
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
    //    auth sum rides inside it as its `$katari_constructor` wire form, headers revealed for the transport
    //    (an MCP server is an allowed sink).
    const listing = await waitUntil(() => transport.dispatched[0]);
    expect(listing.kind).toBe("listTools");
    expect(listing.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: {
        $katari_constructor: "prelude.mcp.headers",
        $katari_value: { values: { authorization: "sk-mcp" } },
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
        $katari_constructor: "prelude.mcp.headers",
        $katari_value: { values: { authorization: "sk-mcp" } },
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
    // What the SDK transport emits for an image-bearing result: the produced blob's slim `$katari_ref`
    // handle riding in `{ text, files }` (see `resolveToolResult`; the producer registered
    // ownership, and the blob's metadata lives on its row — never on the handle).
    transport.feed({
      delegation: toolCall.delegation,
      outcome: {
        kind: "result",
        value: {
          text: "rendered a chart",
          files: [{ $katari_ref: "blob-mcp-image", $katari_semantic_kind: "file" }],
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
        error: {
          $katari_constructor: "prelude.mcp.server_error",
          $katari_value: { message: "listing exploded" },
        },
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

// The `unknown` output schema the codegen stamps on `mcp.call[..., unknown]` (its no-`outputSchema`
// choice): an UNCONSTRAINED `{}`. The reply is decoded UNCONDITIONALLY — the wire's own `$katari_*` markers
// reconstruct the value regardless of `T`, so a reply's `$katari_ref` is a real `file` here exactly as it is
// under a typed `T`. `unknown` differs only in the VALIDATION pass: it accepts whatever the decode produced,
// where a constrained `T` conforms it.
const UNKNOWN_SCHEMA: JSONSchema = {};

// A `file` value's `$katari_ref` handle schema (`Katari.Schema.fileReferenceSchema`): a typed `T` that carries a
// file reconstructs a REAL handle from the reply's `$katari_ref` object, so its lifetime rides the value walk.
const FILE_REF_SCHEMA: JSONSchema = {
  type: "object",
  properties: { $katari_ref: { type: "string" }, $katari_semantic_kind: { type: "string" } },
  required: ["$katari_ref"],
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
//   let arguments = { x = 19, note = "hi" }   // a plain value tree (`arguments: unknown`)
//   // T = unknown: the reply is decoded unconditionally (markers reconstructed) with no validation pass.
//   return mcp.call["https://mcp.example.test/mcp", unknown](url = "https://mcp.example.test/mcp",
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
          // The arguments are an ordinary value tree now (`mcp.call`'s `arguments: unknown`): a plain
          // record `{ x = 19, note = "hi" }`, no `json.json_*` wrappers.
          { kind: "loadLiteral", output: 105, value: { kind: "integer", value: 19 } },
          { kind: "loadLiteral", output: 108, value: { kind: "string", value: "hi" } },
          {
            kind: "makeRecord",
            entries: [
              ["x", 105],
              ["note", 108],
            ],
            output: 111,
          },
          { kind: "loadLiteral", output: 114, value: { kind: "string", value: "add" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 101],
              ["auth", 104],
              ["tool", 114],
              ["arguments", 111],
            ],
            output: 115,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.call") },
            argument: 115,
            output: 116,
            // `mcp.call[url, unknown]` — the codegen's no-`outputSchema` instantiation. The engine
            // forwards this to the mcp reactor as the external agent's ambient, so the reply is decoded
            // unconditionally (the wire's markers reconstructed) with no validation pass.
            generics: directCallGenerics(UNKNOWN_SCHEMA),
          },
          { kind: "exit", target: 24, value: 116 },
        ],
      },
      parameters: { parameter: 100 },
    },
  },
  entries: {
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.mcp.call")]: { block: 2, private: false },
    [createAgentName("prelude.mcp.headers")]: { block: 4, private: false },
    [createAgentName("prelude.json.json_integer")]: { block: 6, private: false },
    [createAgentName("prelude.json.json_string")]: { block: 8, private: false },
    [createAgentName("prelude.json.json_object")]: { block: 20, private: false },
    [createAgentName("prelude.mcp.provide")]: { block: 22, private: false },
    [createAgentName("call_runner")]: { block: 24, private: false },
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
    [createAgentName("main")]: { block: 0, private: false },
    [createAgentName("prelude.mcp.call")]: { block: 2, private: false },
    [createAgentName("prelude.mcp.headers")]: { block: 4, private: false },
  },
  names: {},
};

// The PLAIN document Value a raw-reply test asserts against — a literal lift of the reply (no tagged
// `json` tree anymore: a document is an ordinary record / array / scalar).
const treeString = (value: string): Value => ({ kind: "string", value });
const treeInteger = (value: number): Value => ({ kind: "integer", value });
const treeObject = (fields: Record<string, Value>): Value => ({ kind: "record", fields });

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
    // — no `$katari_constructor` tagging anywhere (that would be the value wire form, which a server does
    // not speak).
    expect(call.argument).toEqual({ x: 19, note: "hi" });
    expect(call.descriptor).toEqual({
      url: "https://mcp.example.test/mcp",
      auth: { $katari_constructor: "prelude.mcp.headers", $katari_value: { values: {} } },
    });

    // `T = unknown` (CALL_IR's instantiation): a marker-free reply decodes to the ordinary record / scalar
    // value it denotes (the unconditional decode leaves a plain object a record), with no validation pass.
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { sum: 42 } },
    });
    await expect(result).resolves.toEqual(treeObject({ sum: treeInteger(42) }));
  });

  test("T = unknown: a plain-text reply becomes a string value", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: "just text" } });
    await expect(result).resolves.toEqual(treeString("just text"));
  });

  test("T = unknown: a blob-bearing reply surfaces its `$katari_ref` handle as a real file value", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: {
          text: "rendered",
          files: [{ $katari_ref: "blob-mcp-image", $katari_semantic_kind: "file" }],
        },
      },
    });
    // The decode is UNCONDITIONAL even at `T = unknown`: the reply's `$katari_ref` is a wire marker, so it
    // reconstructs into a REAL `file` value right at the direct call's own boundary (no schema needed), and
    // the caller receives the real handle — the same value a typed `T` would produce.
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: {
        text: { kind: "string", value: "rendered" },
        files: {
          kind: "array",
          elements: [{ kind: "ref", semanticKind: "file", blobId: "blob-mcp-image" }],
        },
      },
    });
  });

  test("T = unknown: a `$katari_constructor` object decodes to a data value", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // The reply carries the data-value wire marker. The decode is unconditional, so it reconstructs a tagged
    // `data` value (a record with a `ctor`) even at `T = unknown` — the marker, not a schema, drives it.
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: {
          $katari_constructor: "app.render_result",
          $katari_value: { ok: true, count: 3 },
        },
      },
    });
    await expect(result).resolves.toEqual({
      kind: "record",
      fields: { ok: { kind: "boolean", value: true }, count: { kind: "integer", value: 3 } },
      ctor: createAgentName("app.render_result"),
    });
  });

  test("T = unknown: a malformed marker throws json.validation_error (decode is unconditional)", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(CALL_IR, transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await callToolAfterProvide(transport);
    // A `$katari_ref` whose id is not a string is a marker the wire cannot reconstruct. Because the decode is
    // unconditional (not gated on a schema), the failure IS the validation_error even at `T = unknown` — the
    // reactor turns it into the typed throw its row declares, never a panic and never a silent inert record.
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { $katari_ref: 123 } },
    });
    await expect(result).rejects.toThrow(/prelude\.json\.validation_error.*\$katari_ref/);
  });

  test("T = unknown: a produced blob whose id rides only in the raw reply survives to the caller (hoist)", async () => {
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
    // not just a `$katari_ref` string. It targets the `callTool` delegation, the call the blob belongs to.
    const registered = await actor.registerProducedMcpBlob(call.delegation, blob, {
      hash: "hash",
      size: bytes.byteLength,
      semanticKind: "file",
    });
    expect(registered).toBe(true);

    // Even at `T = unknown` the decode is UNCONDITIONAL, so the reply's `$katari_ref` reconstructs a REAL
    // `file` value at the direct call's own boundary — the produced blob ascends by value, no
    // schema-directed backstop involved. And regardless of the value walk, the direct call's `delegateAck`
    // is an upward event: the ownership HOIST reassigns every blob the call still owns onto its core caller,
    // so the blob would reach the caller even if the id rode only in the raw (never-decoded) reply text. The
    // two together — unconditional decode + hoist — are what retired the old per-call run-adoption backstop.
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: { text: "rendered", files: [{ $katari_ref: blob, $katari_semantic_kind: "file" }] },
      },
    });
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

    // Still readable after the whole run settles: the produced blob climbed to the permanent run instance
    // (value walk + hoist) rather than being reclaimed with the ephemeral call.
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

  test("a typed T carrying a file reconstructs a REAL handle that ascends by value", async () => {
    const transport = new ControlledMcpTransport();
    const blobs = new InMemoryBlobStore();
    const blob = "blob-mcp-typed" as BlobId;
    const bytes = new Uint8Array([9, 8, 7, 6]);
    await blobs.put(PROJECT, blob, bytes);
    // T = { text: string, files: array[file] } — the reply's `$katari_ref` reconstructs a REAL file handle.
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
        value: { text: "rendered", files: [{ $katari_ref: blob, $katari_semantic_kind: "file" }] },
      },
    });
    // The `$katari_ref` reconstructs a REAL `ref` value (the decode is unconditional; the typed `T` here only
    // adds a validation pass the value passes), so the file rides the ordinary release / reown walk and its
    // lifetime is value-reachability. The `T = unknown` case above reaches the identical value — the two
    // differ only in whether the result is conformed — which is why the old run-adoption backstop is gone.
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

  test("a reply that does not conform to a typed T throws json.validation_error", async () => {
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
    // The row declares `json.validation_error`; the runtime raises it (never a panic) so a handler catches it.
    await expect(result).rejects.toThrow(/prelude\.json\.validation_error.*does not conform to T/);
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
          $katari_constructor: "prelude.mcp.server_error",
          $katari_value: { message: "connection refused" },
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
