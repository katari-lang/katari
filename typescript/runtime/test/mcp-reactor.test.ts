// End-to-end tests for the built-in `mcp` reactor, driven through the whole ProjectActor (no real MCP
// server — a controlled transport). Two call shapes are covered: `prelude.mcp.tools` (the listing —
// the reactor MINTS one agent value per listed tool, carrying the server descriptor with its privacy
// markers intact) and a minted tool's call (an external delegate straight to the reactor: the caller's
// args verbatim, the tool's descriptor riding its own wire field). Failures are typed
// `throw[mcp.server_error]`; recovery is at-most-once (an interrupted call fails typed — a katari
// retry reconnects through the transport's descriptor cache).

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
import type { DelegationId, ProjectId, SnapshotId } from "../src/runtime/ids.js";
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
