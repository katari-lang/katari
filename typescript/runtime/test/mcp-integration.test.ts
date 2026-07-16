// The built-in MCP path end to end INSIDE the actor (no CLI, no Postgres): a real MCP server on a
// loopback port, the real `SdkMcpTransport`, and a hand-built program that does what `mcp.provide(...)`
// lowers to — open a scoped provider (list once + mint the toolbox), then have the CONTINUATION dispatch
// a minted tool through `reflection.call_agent` inside the scope. Pins the whole chain: SDK client (lazy,
// descriptor-keyed connect) ↔ reactor-side `$tool` minting under a provide scope ↔ emit-site dynamic
// dispatch (schema validation, context riding the external target) ↔ the reactor round-trip.

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import { InMemoryPersistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import type { CredentialStore } from "../src/runtime/external/credentials.js";
import { SdkMcpTransport } from "../src/runtime/external/mcp-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";

const PROJECT = "project-mcp-integration" as ProjectId;
const SNAPSHOT = "snapshot-mcp-integration" as SnapshotId;
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** The transport's now-required credential store; this test's descriptor is `headers`, so it is never
 *  consulted (an oauth read here would be a test bug — fail loudly like the transport stubs do). */
const UNUSED_CREDENTIALS: CredentialStore = {
  load() {
    throw new Error("mcp-integration: no oauth credential should be read on the headers path");
  },
  save() {
    throw new Error("mcp-integration: no oauth credential should be written on the headers path");
  },
};

// agent main(url) {
//   mcp.provide(url = url, auth = mcp.headers(values = {}), continuation = continuation)
// }
// agent continuation(value) {   // dispatched with { value: toolbox } once the listing lands
//   return reflection.call_agent(target = value.value.add, args = { x: 19, y: 23 })
// }
// No connect / close: a tool carries its server DESCRIPTOR, and the transport's descriptor-keyed
// cache (re)connects lazily — connections are not a program-visible resource (the provide scope
// evicts the cached client when it settles).
const MCP_IR: IRModule = {
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
          { kind: "getField", source: 10, field: "url", output: 11 },
          { kind: "makeRecord", entries: [], output: 12 },
          { kind: "makeRecord", entries: [["values", 12]], output: 13 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.headers") },
            argument: 13,
            output: 14,
          },
          { kind: "loadAgent", output: 15, name: createAgentName("continuation") },
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

function readBody(request: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      raw += chunk;
    });
    request.on("end", () => {
      try {
        resolve(raw === "" ? undefined : JSON.parse(raw));
      } catch (error) {
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
    request.on("error", reject);
  });
}

let httpServer: Server;
let url = "";

beforeAll(async () => {
  // A stateless streamable-HTTP MCP server: a fresh server + transport per request.
  httpServer = createServer((request, response) => {
    void (async () => {
      const mcp = new McpServer({ name: "mcp-integration", version: "1.0.0" });
      mcp.registerTool(
        "add",
        { description: "Adds two integers.", inputSchema: { x: z.number(), y: z.number() } },
        ({ x, y }) => ({ content: [{ type: "text", text: String(x + y) }] }),
      );
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      response.on("close", () => {
        void transport.close();
        void mcp.close();
      });
      await mcp.connect(transport);
      await transport.handleRequest(request, response, await readBody(request));
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${(httpServer.address() as AddressInfo).port}/mcp`;
});

afterAll(async () => {
  // The transport's cached client holds a live connection; sever it so close() can complete.
  httpServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    httpServer.close(() => resolve());
  });
});

describe("the built-in mcp path through the actor", () => {
  test("provide: list → mint the scoped toolbox → the continuation dispatches a minted tool via call_agent (lazy connect)", async () => {
    const registry = new SnapshotRegistry();
    for (const name of Object.keys(MCP_IR.entries)) {
      registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), MCP_IR);
    }
    const actor = new ProjectActor({
      projectId: PROJECT,
      ir: registry,
      prims: new PrimRegistry(),
      blobs: new InMemoryBlobStore(),
      external: new StubFfiTransport(),
      http: new StubHttpTransport(),
      mcp: new SdkMcpTransport({ credentials: UNUSED_CREDENTIALS }),
      persistence: new InMemoryPersistence(),
    });
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, {
      kind: "record",
      fields: { url: { kind: "string", value: url } },
    });
    await expect(result).resolves.toEqual({ kind: "string", value: "42" });
  }, 20000);
});
