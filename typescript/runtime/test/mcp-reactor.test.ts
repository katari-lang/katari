// End-to-end tests for the built-in `mcp` reactor, driven through the whole ProjectActor (no real MCP
// server — a controlled transport). Three call shapes are covered: `prelude.mcp.tools` (the listing —
// the reactor MINTS one agent value per listed tool, carrying the server descriptor with its privacy
// markers intact), a minted tool's call (an external delegate straight to the reactor: the caller's
// args verbatim, the tool's descriptor riding its own wire field), and `prelude.mcp.call` (the static
// direct call: `{url, auth, tool, arguments}` all in the argument, the `arguments` json TREE lowered
// to the literal document for the transport and the reply lifted literally back into a tree). Failures
// are typed `throw[mcp.server_error]`; recovery is at-most-once (an interrupted call fails typed — a
// katari retry reconnects through the transport's descriptor cache).

import {
  createAgentName,
  type IRModule,
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
//   let toolbox = prelude.mcp.tools({ url: "https://mcp.example.test/mcp",
//                                     auth: prelude.mcp.headers({ values: { authorization: <private "sk-mcp"> } }) })
//   return reflection.call_agent({ target: toolbox.add, args: { x: 19, y: 23 } })
// }
const TOOLS_IR: IRModule = {
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
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 15],
            ],
            output: 16,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.tools") },
            argument: 16,
            output: 17,
          },
          { kind: "getField", source: 17, field: "add", output: 18 },
          { kind: "loadLiteral", output: 19, value: { kind: "integer", value: 19 } },
          { kind: "loadLiteral", output: 20, value: { kind: "integer", value: 23 } },
          {
            kind: "makeRecord",
            entries: [
              ["x", 19],
              ["y", 20],
            ],
            output: 21,
          },
          {
            kind: "makeRecord",
            entries: [
              ["target", 18],
              ["args", 21],
            ],
            output: 22,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.reflection.call_agent") },
            argument: 22,
            output: 23,
          },
          { kind: "exit", target: 0, value: 23 },
        ],
      },
      parameters: { parameter: 10 },
    },
    2: {
      block: { kind: "agent", body: 3, schema: EMPTY_SCHEMA, description: "", defaults: {} },
      parameters: {},
    },
    3: {
      block: { kind: "external", key: "prelude.mcp.tools", input: 30, reactor: "mcp" },
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
    [createAgentName("prelude.mcp.tools")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
  },
  names: {},
};

/** The listing completion the controlled transport feeds for a `tools` call. */
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

  close(): void {
    this.sink = null;
  }

  feed(completion: McpCompletion): void {
    if (this.sink === null) throw new Error("ControlledMcpTransport: no sink registered");
    this.sink(completion);
  }
}

function makeActor(
  mcp: McpTransport,
  persistence: Persistence = new InMemoryPersistence(),
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(TOOLS_IR.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), TOOLS_IR);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs: new InMemoryBlobStore(),
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
  test("mints the listing into tool agents, then a minted tool's call goes straight back to the reactor", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    // 1. The listing call: a `listTools` dispatch carrying the descriptor read from the argument —
    //    the auth sum rides inside it as its `$constructor` wire form, headers revealed for the
    //    transport (an MCP server is an allowed sink).
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

    // 2. The minted tool's call: a `callTool` dispatch by its server-declared name, the caller's args
    //    verbatim, the descriptor from the minted tool's context.
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
    transport.feed({ delegation: toolCall.delegation, outcome: { kind: "result", value: "42" } });
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
  });

  test("a tool result carrying file handles lifts them into `file` values for the caller", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeActor(transport);
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
    const actor = makeActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

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

  test("an interrupted call recovers as the typed restart throw (at-most-once, never re-run)", async () => {
    const persistence = new StoringPersistence();
    const first = new ControlledMcpTransport();
    const actor = makeActor(first, persistence);
    const { run } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    await waitUntil(() => first.dispatched[0]);

    // Restart: a fresh actor over the same rows. The reloaded in-flight call is recovered, not re-run;
    // the transport refuses with the typed throw, and the run's durable outcome records the error.
    const second = new ControlledMcpTransport();
    const reloaded = makeActor(second, persistence);
    await reloaded.activate();
    await waitUntil(() => second.recovered[0]);
    await waitUntil(() => (persistence.peekRun(run)?.state === "error" ? true : undefined));
    expect(persistence.peekRun(run)?.errorMessage).toContain("interrupted by a runtime restart");
    expect(second.dispatched).toHaveLength(0);
  });
});

// agent main() {
//   let arguments = json.json_object(entries = { x = json.json_integer(value = 19),
//                                                note = json.json_string(value = "hi") })
//   return mcp.call(url = "https://mcp.example.test/mcp",
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
          { kind: "loadLiteral", output: 15, value: { kind: "integer", value: 19 } },
          { kind: "makeRecord", entries: [["value", 15]], output: 16 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_integer") },
            argument: 16,
            output: 17,
          },
          { kind: "loadLiteral", output: 18, value: { kind: "string", value: "hi" } },
          { kind: "makeRecord", entries: [["value", 18]], output: 19 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_string") },
            argument: 19,
            output: 20,
          },
          {
            kind: "makeRecord",
            entries: [
              ["x", 17],
              ["note", 20],
            ],
            output: 21,
          },
          { kind: "makeRecord", entries: [["entries", 21]], output: 22 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.json.json_object") },
            argument: 22,
            output: 23,
          },
          { kind: "loadLiteral", output: 24, value: { kind: "string", value: "add" } },
          {
            kind: "makeRecord",
            entries: [
              ["url", 11],
              ["auth", 14],
              ["tool", 24],
              ["arguments", 23],
            ],
            output: 25,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.call") },
            argument: 25,
            output: 26,
          },
          { kind: "exit", target: 0, value: 26 },
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
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("prelude.mcp.call")]: 2,
    [createAgentName("prelude.mcp.headers")]: 4,
    [createAgentName("prelude.json.json_integer")]: 6,
    [createAgentName("prelude.json.json_string")]: 8,
    [createAgentName("prelude.json.json_object")]: 20,
  },
  names: {},
};

function makeCallActor(
  mcp: McpTransport,
  blobs: InMemoryBlobStore = new InMemoryBlobStore(),
): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(CALL_IR.entries)) {
    registry.set(SNAPSHOT, moduleOfName(name as QualifiedName), CALL_IR);
  }
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims: new PrimRegistry(),
    blobs,
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    mcp,
    persistence: new InMemoryPersistence(),
  });
}

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

describe("mcp reactor: the direct call (prelude.mcp.call)", () => {
  test("lowers the arguments TREE to the literal document and ships the same callTool operation", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeCallActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
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

    // A structured reply lifts LITERALLY into the `json` tree the caller receives.
    transport.feed({
      delegation: call.delegation,
      outcome: { kind: "result", value: { sum: 42 } },
    });
    await expect(result).resolves.toEqual(treeObject({ sum: treeInteger(42) }));
  });

  test("a plain-text reply becomes a json_string tree", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeCallActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
    transport.feed({ delegation: call.delegation, outcome: { kind: "result", value: "just text" } });
    await expect(result).resolves.toEqual(treeString("just text"));
  });

  test("a blob-bearing reply keeps the `$ref` handle as a LITERAL object inside the tree", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeCallActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
    transport.feed({
      delegation: call.delegation,
      outcome: {
        kind: "result",
        value: { text: "rendered", files: [{ $ref: "blob-mcp-image", semanticKind: "file" }] },
      },
    });
    // The handle is NOT lifted into a `file` value here (that is `json.decode`'s job, against a
    // `file`-typed shape); it must survive as the literal `$ref` object inside the tree.
    await expect(result).resolves.toEqual(
      treeObject({
        text: treeString("rendered"),
        files: treeArray([
          treeObject({ $ref: treeString("blob-mcp-image"), semanticKind: treeString("file") }),
        ]),
      }),
    );
  });

  test("a REAL produced blob survives the direct call, ascending onto the run (still readable after)", async () => {
    const transport = new ControlledMcpTransport();
    const blobs = new InMemoryBlobStore();
    const blob = "blob-mcp-direct" as BlobId;
    const bytes = new Uint8Array([1, 2, 3, 4]);
    await blobs.put(PROJECT, blob, bytes);
    const actor = makeCallActor(transport, blobs);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
    // The transport produced a blob from a tool result's image content mid-call: register its ownership
    // (bytes already staged above), exactly as the SDK transport's blob bridge does — a REAL produced blob,
    // not just a `$ref` string.
    const registered = await actor.registerProducedMcpBlob(call.delegation, blob, {
      hash: "hash",
      size: bytes.byteLength,
      semanticKind: "file",
    });
    expect(registered).toBe(true);

    // The reply lifts LITERALLY into the json tree — the blob rides only as a `$ref` STRING leaf, not a
    // real ref, so the value-driven resource ascent cannot carry it.
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

    // The handle is still readable after the call settles: the produced blob ascended onto the (permanent)
    // run instance rather than being reclaimed with the ephemeral call. The OLD code — which left a
    // produced blob the literal `$ref` tree did not carry out owned by the call instance — deleted these
    // bytes in the same commit that delivered the result, so this read would have failed.
    await expect(blobs.get(PROJECT, blob)).resolves.toEqual(bytes);
  });

  test("a transport error surfaces as the typed throw[mcp.server_error]", async () => {
    const transport = new ControlledMcpTransport();
    const actor = makeCallActor(transport);
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);

    const call = await waitUntil(() => transport.dispatched[0]);
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
});
