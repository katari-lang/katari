// End-to-end tests for `mcp.serve` — publishing a program's own agents as a stateless MCP server for
// the extent of a subscriber. Driven at two altitudes:
//   - through the whole ProjectActor (no HTTP): a hand-built program calls
//     `mcp.serve(tools = {...}, subscriber = ...)`; the mcp reactor mints a token, dispatches the
//     subscriber once with the capability URL, lists the served record through the same
//     `callableMetadata` reflection as `reflection.get_metadata`, and converts each `tools/call`
//     into a delegation of the named agent — covering value / throw / schema-violation outcomes,
//     settlement with the subscriber, cancellation deactivating the token, and the restart contract
//     (token + tools reload from the `mcp_instances` serve columns);
//   - through the hand-rolled JSON-RPC layer (`serveMcpMessage`) with the REAL SDK client over
//     `StreamableHTTPClientTransport` against a live loopback server, pinning wire compatibility of
//     the stateless POST-only contract (initialize / tools/list / tools/call, 405 on GET, 404 on a
//     dead token) and that a secret in a result redacts at this user-facing boundary.

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { mcpServeEndpointOf, serveMcpMessage } from "../src/modules/mcp/mcp-serve.js";
import { InMemoryPersistence, type Persistence } from "../src/runtime/actor/persistence.js";
import { ProjectActor } from "../src/runtime/actor/project-actor.js";
import { StoringPersistence } from "../src/runtime/actor/storing-persistence.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { StubHttpTransport } from "../src/runtime/external/http-transport.js";
import { StubFfiTransport } from "../src/runtime/external/runner.js";
import type { ProjectId, SnapshotId } from "../src/runtime/ids.js";
import { moduleOfName, SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-mcp-serve" as ProjectId;
const SNAPSHOT = "snapshot-mcp-serve" as SnapshotId;
const PUBLIC_BASE = "https://runtime.example";
const EMPTY_SCHEMA: SchemaInfo = { input: {}, output: {}, requests: [], genericBindings: {} };

/** `echo(message: string) -> string` — what a served call's arguments are validated against. */
const ECHO_SCHEMA: SchemaInfo = {
  input: {
    type: "object",
    properties: { message: { type: "string" } },
    required: ["message"],
    additionalProperties: false,
  },
  output: { type: "string" },
  requests: [],
  genericBindings: {},
};

/** `wrap(message: string) -> { echoed: string }` — an object output, so the listing advertises an
 *  `outputSchema` and a result must carry `structuredContent` (the SDK client enforces exactly that). */
const WRAP_SCHEMA: SchemaInfo = {
  input: {
    type: "object",
    properties: { message: { type: "string" } },
    required: ["message"],
    additionalProperties: false,
  },
  output: {
    type: "object",
    properties: { echoed: { type: "string" } },
    required: ["echoed"],
    additionalProperties: false,
  },
  requests: [],
  genericBindings: {},
};

/**
 * agent main() { mcp.serve(tools = { echo, wrap, boom, secret_reply }, subscriber = subscriber) }
 * agent echo(message: string) -> string { message }
 * agent wrap(message: string) -> { echoed: string } { { echoed = message } }
 * agent boom() { throw({ message = "boom" }) }
 * agent secret_reply() -> string { secret() }              // a private string — must redact outbound
 * agent subscriber(url) { wait(url = url) }                // an unhandled request: an open, durable question
 */
const SERVE_IR: IRModule = {
  metadata: { schemaVersion: 1 },
  blocks: {
    0: { block: { kind: "agent", body: 1, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    1: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadAgent", output: 11, name: createAgentName("echo") },
          { kind: "loadAgent", output: 12, name: createAgentName("wrap") },
          { kind: "loadAgent", output: 13, name: createAgentName("boom") },
          { kind: "loadAgent", output: 14, name: createAgentName("secret_reply") },
          {
            kind: "makeRecord",
            entries: [
              ["echo", 11],
              ["wrap", 12],
              ["boom", 13],
              ["secret_reply", 14],
            ],
            output: 15,
          },
          { kind: "loadAgent", output: 16, name: createAgentName("subscriber") },
          {
            kind: "makeRecord",
            entries: [
              ["tools", 15],
              ["subscriber", 16],
            ],
            output: 17,
          },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.mcp.serve") },
            argument: 17,
            output: 18,
          },
          { kind: "exit", target: 0, value: 18 },
        ],
      },
      parameters: { parameter: 10 },
    },
    // echo: returns its validated `message`.
    2: {
      block: {
        kind: "agent",
        body: 3,
        schema: ECHO_SCHEMA,
        description: "Echoes the message.",
        defaults: {},
      },
      parameters: {},
    },
    3: {
      block: {
        kind: "sequence",
        result: 21,
        operations: [{ kind: "getField", source: 20, field: "message", output: 21 }],
      },
      parameters: { parameter: 20 },
    },
    // wrap: returns `{ echoed: message }` — the structured-content shape.
    4: {
      block: {
        kind: "agent",
        body: 5,
        schema: WRAP_SCHEMA,
        description: "Wraps the message in a record.",
        defaults: {},
      },
      parameters: {},
    },
    5: {
      block: {
        kind: "sequence",
        result: 32,
        operations: [
          { kind: "getField", source: 30, field: "message", output: 31 },
          { kind: "makeRecord", entries: [["echoed", 31]], output: 32 },
        ],
      },
      parameters: { parameter: 30 },
    },
    // boom: raises `prelude.throw({ message: "boom" })` — the MCP tool-error case.
    6: { block: { kind: "agent", body: 7, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    7: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "loadLiteral", output: 41, value: { kind: "string", value: "boom" } },
          { kind: "makeRecord", entries: [["message", 41]], output: 42 },
          { kind: "makeRecord", entries: [["error", 42]], output: 43 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.throw") },
            argument: 43,
            output: 44,
          },
          { kind: "exit", target: 6, value: 44 },
        ],
      },
      parameters: { parameter: 40 },
    },
    // secret_reply: returns the (private) secret — a redaction probe for the outbound boundary.
    8: { block: { kind: "agent", body: 9, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    9: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "makeRecord", entries: [], output: 51 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("prelude.secret") },
            argument: 51,
            output: 52,
          },
          { kind: "exit", target: 8, value: 52 },
        ],
      },
      parameters: { parameter: 50 },
    },
    // mcp.serve: the external leaf routed to the mcp reactor under its compiled qualified key.
    10: { block: { kind: "agent", body: 11, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    11: {
      block: { kind: "external", key: "prelude.mcp.serve", input: 60, reactor: "mcp" },
      parameters: { parameter: 60 },
    },
    // subscriber: forwards the minted url to its blocking `wait` request and returns its answer.
    12: { block: { kind: "agent", body: 13, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    13: {
      block: {
        kind: "sequence",
        result: null,
        operations: [
          { kind: "getField", source: 70, field: "url", output: 71 },
          { kind: "makeRecord", entries: [["url", 71]], output: 72 },
          {
            kind: "delegate",
            target: { kind: "name", name: createAgentName("wait") },
            argument: 72,
            output: 73,
          },
          { kind: "exit", target: 12, value: 73 },
        ],
      },
      parameters: { parameter: 70 },
    },
    // wait: an unhandled request — escalates to the run root as an open (durable) question.
    14: { block: { kind: "agent", body: 15, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    15: {
      block: { kind: "request", name: createAgentName("wait"), input: 80 },
      parameters: { parameter: 80 },
    },
    // The `prelude.throw` wrapper a compiled raise delegates to.
    16: { block: { kind: "agent", body: 17, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    17: {
      block: { kind: "request", name: createAgentName("prelude.throw"), input: 90 },
      parameters: { parameter: 90 },
    },
    // The `prelude.secret` prim wrapper (the registry returns a private string).
    18: { block: { kind: "agent", body: 19, schema: EMPTY_SCHEMA, description: "", defaults: {} }, parameters: {} },
    19: {
      block: { kind: "primitive", name: "prelude.secret", input: 95 },
      parameters: { parameter: 95 },
    },
  },
  entries: {
    [createAgentName("main")]: 0,
    [createAgentName("echo")]: 2,
    [createAgentName("wrap")]: 4,
    [createAgentName("boom")]: 6,
    [createAgentName("secret_reply")]: 8,
    [createAgentName("prelude.mcp.serve")]: 10,
    [createAgentName("subscriber")]: 12,
    [createAgentName("wait")]: 14,
    [createAgentName("prelude.throw")]: 16,
    [createAgentName("prelude.secret")]: 18,
  },
  names: {},
};

function actorFor(persistence: Persistence = new InMemoryPersistence()): ProjectActor {
  const registry = new SnapshotRegistry();
  for (const name of Object.keys(SERVE_IR.entries)) {
    registry.set(SNAPSHOT, moduleOfName(createAgentName(name)), SERVE_IR);
  }
  const prims = new PrimRegistry();
  prims.register("prelude.secret", () => ({ kind: "string", value: "sk-123", private: true }));
  return new ProjectActor({
    projectId: PROJECT,
    ir: registry,
    prims,
    blobs: new InMemoryBlobStore(),
    external: new StubFfiTransport(),
    http: new StubHttpTransport(),
    publicBaseUrl: PUBLIC_BASE,
    persistence,
  });
}

/** Poll until `read` yields a value (the reactor turns are asynchronous, so the test observes, not steps). */
async function eventually<T>(read: () => T | undefined): Promise<T> {
  for (let attempt = 0; attempt < 400; attempt += 1) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("condition not reached in time");
}

/** The minted capability URL rides the subscriber's open `wait` escalation; extract its token. */
async function mintedToken(actor: ProjectActor): Promise<string> {
  const escalation = await eventually(() => actor.listOpenEscalations()[0]);
  const argument = escalation.argument;
  if (argument === null || argument.kind !== "record" || argument.fields.url?.kind !== "string") {
    throw new Error("the wait escalation does not carry the minted url");
  }
  const url = argument.fields.url.value;
  expect(url).toMatch(new RegExp(`^${PUBLIC_BASE}/mcp/[A-Za-z0-9_-]+$`));
  return url.split("/mcp/")[1] ?? "";
}

function bodyOf(fields: Record<string, Value>): Value {
  return { kind: "record", fields };
}

const HELLO = bodyOf({ message: { kind: "string", value: "hello" } });

describe("the mcp reactor (serve, through the actor)", () => {
  test("mints a capability URL and lists the served record's tools with their real schemas", async () => {
    const actor = actorFor();
    actor.startRun(createAgentName("main"), SNAPSHOT, null);
    const token = await mintedToken(actor);

    await expect(actor.probeMcpServe(token)).resolves.toBe(true);
    const described = await actor.listMcpServeTools(token);
    if (described.kind !== "tools") throw new Error("expected a live tools listing");
    // The record key is the published name, in stable (sorted) order.
    expect(described.tools.map((tool) => tool.name)).toEqual([
      "boom",
      "echo",
      "secret_reply",
      "wrap",
    ]);
    const echo = described.tools.find((tool) => tool.name === "echo");
    expect(echo?.description).toBe("Echoes the message.");
    expect(echo?.input).toEqual(ECHO_SCHEMA.input);
    expect(echo?.output).toEqual(ECHO_SCHEMA.output);

    // A token nobody minted resolves `unknown` (and probes dead).
    await expect(actor.listMcpServeTools("no-such-token")).resolves.toEqual({ kind: "unknown" });
    await expect(actor.probeMcpServe("no-such-token")).resolves.toBe(false);
  });

  test("a tools/call round-trips into the agent and back: value, throw, violation, unknown tool", async () => {
    const actor = actorFor();
    actor.startRun(createAgentName("main"), SNAPSHOT, null);
    const token = await mintedToken(actor);

    // A conforming call runs the agent; its result is the tool result.
    await expect(actor.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // A throwing agent surfaces as the typed throw (the endpoint maps it to an MCP tool error).
    const thrown = await actor.deliverMcpServeCall(token, "boom", bodyOf({}));
    expect(thrown.kind).toBe("throw");
    if (thrown.kind === "throw" && thrown.value.kind === "record") {
      expect(thrown.value.fields.message).toEqual({ kind: "string", value: "boom" });
    }

    // A violating call fails at the delegation boundary — a typed `reflection.call_error`, the agent
    // never runs, the endpoint stays live.
    const violation = await actor.deliverMcpServeCall(
      token,
      "echo",
      bodyOf({ wrong: { kind: "integer", value: 1 } }),
    );
    expect(violation.kind).toBe("throw");
    if (violation.kind === "throw" && violation.value.kind === "record") {
      expect(String(violation.value.ctor)).toBe("prelude.reflection.call_error");
    }

    // A name the record does not serve is the caller's mistake, not a dead endpoint.
    await expect(actor.deliverMcpServeCall(token, "nope", HELLO)).resolves.toEqual({
      kind: "unknownTool",
    });
  });

  test("the call settles when the subscriber settles, and the endpoint deactivates", async () => {
    const actor = actorFor();
    const { result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    const token = await mintedToken(actor);

    const open = await eventually(() => actor.listOpenEscalations()[0]);
    await actor.answerEscalation(open.escalation, { kind: "string", value: "unsubscribed" });
    // The subscriber's result IS `mcp.serve`'s result — and the run's.
    await expect(result).resolves.toEqual({ kind: "string", value: "unsubscribed" });
    await expect(actor.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "unknown",
    });
    await expect(actor.probeMcpServe(token)).resolves.toBe(false);
  });

  test("cancelling the run deactivates the URL", async () => {
    const actor = actorFor();
    const { run, result } = actor.startRun(createAgentName("main"), SNAPSHOT, null);
    // The in-process result promise rejects with the cancel — the durable outcome is what matters here.
    void result.catch(() => {});
    const token = await mintedToken(actor);
    await expect(actor.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    await actor.cancelRun(run, "done with it");
    // The abort releases the token; from then on the capability URL answers nothing.
    await eventually(() => (actor.listOpenEscalations().length === 0 ? true : undefined));
    await expect(actor.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "unknown",
    });
    // The HTTP layer reads the same deactivation as a 404.
    const reply = await serveMcpMessage(
      mcpServeEndpointOf(actor, token),
      JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }),
    );
    expect(reply.status).toBe(404);
  });
});

describe("the mcp reactor (serve, restart survival)", () => {
  test("the endpoint outlives a restart: token + tools reload and re-register", async () => {
    const persistence = new StoringPersistence();
    const first = actorFor(persistence);
    const { run } = first.startRun(createAgentName("main"), SNAPSHOT, null);
    const token = await mintedToken(first);
    await expect(first.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // Restart: a fresh actor over the same durable rows. The endpoint must still serve — the token and
    // the tools record reload from the `mcp_instances` serve columns; nothing is re-dispatched.
    const second = actorFor(persistence);
    await second.activate();
    const described = await second.listMcpServeTools(token);
    if (described.kind !== "tools") throw new Error("expected the reloaded endpoint to list tools");
    expect(described.tools.map((tool) => tool.name)).toContain("echo");
    await expect(second.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "result",
      value: { kind: "string", value: "hello" },
    });

    // Answering the subscriber's question ends the serving; the run completes with the answer and the
    // endpoint deactivates — durably (no mcp instance survives).
    const reloaded = await eventually(() => second.listOpenEscalations()[0]);
    await second.answerEscalation(reloaded.escalation, { kind: "string", value: "unsubscribed" });
    await eventually(() => (persistence.peekRun(run)?.state === "done" ? true : undefined));
    expect(persistence.peekRun(run)?.result).toEqual({ kind: "string", value: "unsubscribed" });
    await expect(second.deliverMcpServeCall(token, "echo", HELLO)).resolves.toEqual({
      kind: "unknown",
    });
    expect(persistence.envelopeCount("mcp")).toBe(0);
  });
});

// ─── the wire contract, driven by the real SDK client over a live loopback server ─────────────────

let httpServer: Server;
let baseUrl = "";
let serveActor: ProjectActor;
let serveToken = "";

function readBody(request: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    let raw = "";
    request.setEncoding("utf8");
    request.on("data", (chunk: string) => {
      raw += chunk;
    });
    request.on("end", () => resolve(raw));
    request.on("error", reject);
  });
}

beforeAll(async () => {
  serveActor = actorFor();
  serveActor.startRun(createAgentName("main"), SNAPSHOT, null);
  serveToken = await mintedToken(serveActor);
  // A loopback stand-in for the runtime's route: `POST /mcp/<token>` feeds the hand-rolled JSON-RPC
  // handler over the actor-backed endpoint; everything else is 405, like the stateless route.
  httpServer = createServer((request, response) => {
    void (async () => {
      if (request.method !== "POST") {
        response.writeHead(405, { Allow: "POST" }).end();
        return;
      }
      const token = (request.url ?? "").split("/mcp/")[1] ?? "";
      const reply = await serveMcpMessage(
        mcpServeEndpointOf(serveActor, token),
        await readBody(request),
      );
      if (reply.body === null) {
        response.writeHead(202).end();
        return;
      }
      response
        .writeHead(reply.status, { "Content-Type": "application/json" })
        .end(JSON.stringify(reply.body));
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  baseUrl = `http://127.0.0.1:${(httpServer.address() as AddressInfo).port}`;
});

afterAll(async () => {
  httpServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    httpServer.close(() => resolve());
  });
});

describe("the mcp serve wire contract (real SDK client, stateless streamable http)", () => {
  test("initialize → tools/list → tools/call, all shapes", async () => {
    const client = new Client({ name: "mcp-serve-test", version: "1.0.0" });
    await client.connect(new StreamableHTTPClientTransport(new URL(`${baseUrl}/mcp/${serveToken}`)));
    try {
      // The listing carries the record keys as names and the agents' real schemas; only the
      // object-shaped output advertises an outputSchema (see `mcp-serve.ts`).
      const listing = await client.listTools();
      const names = listing.tools.map((tool) => tool.name).sort();
      expect(names).toEqual(["boom", "echo", "secret_reply", "wrap"]);
      const echo = listing.tools.find((tool) => tool.name === "echo");
      expect(echo?.inputSchema).toEqual(ECHO_SCHEMA.input);
      expect(echo?.outputSchema).toBeUndefined();
      const wrap = listing.tools.find((tool) => tool.name === "wrap");
      expect(wrap?.outputSchema).toEqual(WRAP_SCHEMA.output);

      // A string result is text content.
      const echoed = await client.callTool({ name: "echo", arguments: { message: "hello" } });
      expect(echoed.content).toEqual([{ type: "text", text: "hello" }]);

      // An object result is structured content (plus the spec-required text fallback) — and the SDK
      // client validates it against the advertised output schema.
      const wrapped = await client.callTool({ name: "wrap", arguments: { message: "hi" } });
      expect(wrapped.structuredContent).toEqual({ echoed: "hi" });
      expect(wrapped.content).toEqual([{ type: "text", text: '{"echoed":"hi"}' }]);

      // A typed throw is an MCP tool error carrying the error JSON.
      const boom = await client.callTool({ name: "boom", arguments: {} });
      expect(boom.isError).toBe(true);
      expect(JSON.stringify(boom.content)).toContain("boom");

      // A schema violation is the JSON-RPC invalid-params error — the agent never ran.
      await expect(
        client.callTool({ name: "echo", arguments: { wrong: 1 } }),
      ).rejects.toThrow(/schema/);

      // An unserved name is invalid params too, not a dead endpoint.
      await expect(client.callTool({ name: "nope", arguments: {} })).rejects.toThrow(/not served/);

      // A secret in a result redacts at this user-facing boundary — the material never crosses.
      const secret = await client.callTool({ name: "secret_reply", arguments: {} });
      expect(JSON.stringify(secret)).not.toContain("sk-123");
      expect(secret.structuredContent).toEqual({ $redacted: true });
    } finally {
      await client.close();
    }
  }, 20000);

  test("a dead token answers 404 to every method", async () => {
    const response = await fetch(`${baseUrl}/mcp/no-such-token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "x", version: "0" } },
      }),
    });
    expect(response.status).toBe(404);
    const listed = await fetch(`${baseUrl}/mcp/no-such-token`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" }),
    });
    expect(listed.status).toBe(404);
  });

  test("notifications are acknowledged with 202 and non-POST with 405", async () => {
    const notified = await fetch(`${baseUrl}/mcp/${serveToken}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }),
    });
    expect(notified.status).toBe(202);
    const got = await fetch(`${baseUrl}/mcp/${serveToken}`, { method: "GET" });
    expect(got.status).toBe(405);
  });
});
