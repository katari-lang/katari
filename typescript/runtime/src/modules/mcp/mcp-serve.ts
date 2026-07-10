// The MCP serve protocol layer: the stateless JSON-RPC handling behind `POST /mcp/<token>` (the URLs
// `mcp.serve` mints), split from the route so a test can drive the exact wire contract against a live
// actor without HTTP. The handling is HAND-ROLLED rather than bridged through the SDK's
// `StreamableHTTPServerTransport`: that transport wants raw node req/res and its own server lifecycle,
// while this server is Hono-served and every tool call must route through the project actor's serial
// turn anyway — wrapping that in an `McpServer` instance per request would add the SDK's machinery
// around the same four methods. Stateless MCP (`sessionIdGenerator: undefined` in SDK terms) needs
// exactly: `initialize`, the `notifications/*` acks, `tools/list`, and `tools/call` — POST-only JSON
// responses (no SSE stream, no session id), which also survives runtime restarts for free. The suite
// drives this handler with the real SDK client to pin wire compatibility.
//
// The `McpServeEndpoint` port keeps the two halves apart: `mcpServeEndpointOf` adapts a project actor
// (engine `Value`s in and out — lowered HERE, at the user-facing boundary, so private content redacts),
// and `serveMcpMessage` maps the port's outcomes onto JSON-RPC. Outcome → wire:
//   - a returned value: a tool result — a bare string as text content, an object additionally as
//     `structuredContent` (the spec types `structuredContent` as an OBJECT, so any other JSON rides as
//     its text form only — which is also why a non-object output schema is not advertised: the SDK
//     client hard-requires structured content from any tool that declares one);
//   - a typed throw: an MCP tool error (`isError: true`, the error JSON as text) — EXCEPT a
//     `reflection.call_error` (the dispatch-boundary schema violation: the agent never ran), which is
//     the JSON-RPC `invalid params` error, exactly like the SDK server's own argument validation;
//   - a panic: a bare `internal error` (details stay server-side);
//   - a dead token: HTTP 404 (no such endpoint) / 410 (winding down) — cancellation deactivates the URL.

import type { Json } from "@katari-lang/types";
import { messageOf } from "../../runtime/actor/failure.js";
import type { ProjectActor } from "../../runtime/actor/project-actor.js";
import { jsonToValue, valueToJson } from "../../runtime/value/codec.js";
import { schemaToJson } from "../../runtime/value/schema-json.js";
import type { Value } from "../../runtime/value/types.js";

/** The Json-level port `serveMcpMessage` serves from — a live endpoint adapted from a project actor,
 *  or the `unknown` stand-in when no durable row resolves the token. */
export interface McpServeEndpoint {
  /** Whether a live endpoint holds the token (the `initialize` liveness probe). */
  probe(): Promise<boolean>;
  listTools(): Promise<
    | { kind: "unknown" }
    | {
        kind: "tools";
        tools: Array<{ name: string; description: string; inputSchema: Json; outputSchema?: Json }>;
      }
  >;
  callTool(
    name: string,
    argument: Json,
  ): Promise<
    | { kind: "unknown" }
    | { kind: "gone" }
    | { kind: "unknownTool" }
    /** Rejected before the agent ran (undecodable / schema-violating arguments). */
    | { kind: "rejected"; message: string }
    | { kind: "result"; value: Json }
    | { kind: "throw"; error: Json }
    /** The agent panicked; details stay server-side. */
    | { kind: "error" }
  >;
}

/** One handled inbound MCP message, as the HTTP reply the route writes: a `202` acknowledges a
 *  notification (no body); everything else carries a JSON-RPC response body. */
export interface McpServeHttpReply {
  status: 200 | 202 | 400 | 404 | 405 | 410;
  body: Json | null;
}

// The standard JSON-RPC error codes plus one server-defined code for a dead capability URL.
const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603;
const ENDPOINT_UNAVAILABLE = -32000;

/** The protocol revisions this stateless server knows to be compatible with its POST-only JSON
 *  responses. `initialize` echoes the client's requested revision when it is one of these, and offers
 *  the newest otherwise (the spec's downgrade path). */
const KNOWN_PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];

/** Handle one inbound MCP POST body against an endpoint. Exactly the stateless method set: `initialize`
 *  (a liveness probe + capability advertisement), notifications (acknowledged and dropped — no session
 *  to advance), `ping`, `tools/list`, and `tools/call`. */
export async function serveMcpMessage(
  endpoint: McpServeEndpoint,
  raw: string,
): Promise<McpServeHttpReply> {
  let message: Json;
  try {
    message = raw === "" ? null : (JSON.parse(raw) as Json);
  } catch {
    return { status: 400, body: errorBody(null, PARSE_ERROR, "the request body is not JSON") };
  }
  if (!isJsonObject(message) || message.jsonrpc !== "2.0" || typeof message.method !== "string") {
    // Batching was removed from the protocol (2025-06-18) and a stateless server has no in-flight
    // requests a client-sent response could answer, so anything but a single request/notification
    // frame is an invalid request.
    return {
      status: 400,
      body: errorBody(null, INVALID_REQUEST, "expected a single JSON-RPC 2.0 request"),
    };
  }
  const method = message.method;
  const id = message.id;
  if (typeof id !== "string" && typeof id !== "number") {
    // A notification (`notifications/initialized`, `notifications/cancelled`): acknowledged and
    // dropped — stateless serving has no session to advance and no request registry to cancel into.
    return { status: 202, body: null };
  }
  const params = isJsonObject(message.params) ? message.params : {};
  switch (method) {
    case "initialize": {
      if (!(await endpoint.probe())) {
        return { status: 404, body: unavailableBody(id) };
      }
      const requested = params.protocolVersion;
      return {
        status: 200,
        body: resultBody(id, {
          protocolVersion:
            typeof requested === "string" && KNOWN_PROTOCOL_VERSIONS.includes(requested)
              ? requested
              : (KNOWN_PROTOCOL_VERSIONS[0] ?? "2025-06-18"),
          capabilities: { tools: {} },
          serverInfo: { name: "katari-mcp-serve", version: "0.1.0" },
        }),
      };
    }
    case "ping":
      return { status: 200, body: resultBody(id, {}) };
    case "tools/list": {
      const listing = await endpoint.listTools();
      if (listing.kind === "unknown") {
        return { status: 404, body: unavailableBody(id) };
      }
      const tools: Json[] = listing.tools.map((tool) => ({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.inputSchema,
        ...(tool.outputSchema !== undefined ? { outputSchema: tool.outputSchema } : {}),
      }));
      return { status: 200, body: resultBody(id, { tools }) };
    }
    case "tools/call":
      return serveToolCall(endpoint, id, params);
    default:
      return {
        status: 200,
        body: errorBody(id, METHOD_NOT_FOUND, `method "${method}" is not supported`),
      };
  }
}

/** The `tools/call` half of the handler: dispatch the named tool and map its outcome onto the wire
 *  (see the module comment for the outcome → wire table). */
async function serveToolCall(
  endpoint: McpServeEndpoint,
  id: string | number,
  params: { [key: string]: Json },
): Promise<McpServeHttpReply> {
  const name = params.name;
  if (typeof name !== "string") {
    return {
      status: 200,
      body: errorBody(id, INVALID_PARAMS, "tools/call requires a string tool name"),
    };
  }
  const outcome = await endpoint.callTool(name, params.arguments ?? {});
  switch (outcome.kind) {
    case "unknown":
      return { status: 404, body: unavailableBody(id) };
    case "gone":
      return {
        status: 410,
        body: errorBody(id, ENDPOINT_UNAVAILABLE, "this MCP endpoint is no longer serving"),
      };
    case "unknownTool":
      return {
        status: 200,
        body: errorBody(id, INVALID_PARAMS, `tool "${name}" is not served here`),
      };
    case "rejected":
      return { status: 200, body: errorBody(id, INVALID_PARAMS, outcome.message) };
    case "result":
      return { status: 200, body: resultBody(id, callToolResultOf(outcome.value)) };
    case "throw":
      return {
        status: 200,
        body: resultBody(id, {
          content: [{ type: "text", text: JSON.stringify(outcome.error) }],
          isError: true,
        }),
      };
    case "error":
      return { status: 200, body: errorBody(id, INTERNAL_ERROR, "the tool call failed") };
  }
}

/** Adapt a project actor into the endpoint port for one token. This is the user-facing boundary:
 *  every engine value lowers with `redact` (a secret in a result must collapse, exactly like the
 *  webhook reply path), and a dispatch-boundary `reflection.call_error` becomes the `rejected`
 *  variant (the agent never ran — the caller's arguments were bad, not the program). */
export function mcpServeEndpointOf(actor: ProjectActor, token: string): McpServeEndpoint {
  return {
    probe: () => actor.probeMcpServe(token),
    async listTools() {
      const described = await actor.listMcpServeTools(token);
      if (described.kind === "unknown") return { kind: "unknown" };
      return {
        kind: "tools",
        tools: described.tools.map((tool) => {
          const output = schemaToJson(tool.output);
          return {
            name: tool.name,
            description: tool.description,
            inputSchema: objectSchemaJson(schemaToJson(tool.input)),
            // Only an object-shaped output schema is advertised: `structuredContent` is spec-typed as
            // an object, and the SDK client hard-requires it from any tool that declares a schema —
            // so a string-returning agent advertises no output schema rather than an unfulfillable one.
            ...(isJsonObject(output) && output.type === "object" ? { outputSchema: output } : {}),
          };
        }),
      };
    },
    async callTool(name, argument) {
      let decoded: Value;
      try {
        decoded = jsonToValue(argument);
      } catch (error) {
        // A reserved `$`-key or an undecodable handle in the arguments — the caller's fault, the
        // same class as a schema violation, so it maps to `invalid params` without touching the run.
        return {
          kind: "rejected",
          message: `the arguments are not decodable: ${messageOf(error)}`,
        };
      }
      const outcome = await actor.deliverMcpServeCall(token, name, decoded);
      switch (outcome.kind) {
        case "unknown":
        case "gone":
        case "unknownTool":
          return { kind: outcome.kind };
        case "result":
          return { kind: "result", value: valueToJson(outcome.value, "redact") };
        case "throw":
          return isCallError(outcome.value)
            ? { kind: "rejected", message: callErrorMessageOf(outcome.value) }
            : { kind: "throw", error: valueToJson(outcome.value, "redact") };
        case "error":
          // The panic message stays server-side (it may name internals); the caller gets a bare error.
          return { kind: "error" };
      }
    },
  };
}

/** The endpoint behind a token no durable row resolves: every read answers `unknown`, so the handler's
 *  one dead-token mapping (404) covers the no-row and the no-warm-call cases identically. */
export function unknownMcpServeEndpoint(): McpServeEndpoint {
  return {
    async probe() {
      return false;
    },
    async listTools() {
      return { kind: "unknown" };
    },
    async callTool() {
      return { kind: "unknown" };
    },
  };
}

/** Whether a thrown payload is the dynamic-dispatch schema violation (`reflection.call_error`). Shared
 *  with the webhook reply path in the facade — both boundaries turn it into "the caller's request was
 *  bad" rather than "the program failed". */
export function isCallError(value: Value): boolean {
  return value.kind === "record" && String(value.ctor) === "prelude.reflection.call_error";
}

/** The human-readable half of a `reflection.call_error` (its `message` field), for the JSON-RPC
 *  `invalid params` message. */
function callErrorMessageOf(value: Value): string {
  if (value.kind === "record" && value.fields.message?.kind === "string") {
    return value.fields.message.value;
  }
  return "the arguments do not conform to the tool's input schema";
}

/** A tool result's wire form: a bare string is text content; an object rides as `structuredContent`
 *  with the spec-required text fallback; any other JSON rides as its text form only (the spec types
 *  `structuredContent` as an object). */
function callToolResultOf(value: Json): Json {
  if (typeof value === "string") {
    return { content: [{ type: "text", text: value }] };
  }
  const text = JSON.stringify(value);
  if (isJsonObject(value)) {
    return { content: [{ type: "text", text }], structuredContent: value };
  }
  return { content: [{ type: "text", text }] };
}

/** MCP requires an OBJECT input schema on every tool. A katari agent's input is always a record of
 *  named parameters, but an empty `{}` (unknown) schema carries no `type` keyword — stamp it, so a
 *  strict client accepts the listing. */
function objectSchemaJson(schema: Json): Json {
  if (isJsonObject(schema) && schema.type === undefined) return { ...schema, type: "object" };
  return schema;
}

function resultBody(id: string | number, result: Json): Json {
  return { jsonrpc: "2.0", id, result };
}

function errorBody(id: string | number | null, code: number, message: string): Json {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

/** The one dead-token error body (`404` rides it): the URL is the capability, so a token nobody serves
 *  and a token that was deactivated read identically to the caller. */
function unavailableBody(id: string | number): Json {
  return errorBody(id, ENDPOINT_UNAVAILABLE, "no MCP endpoint serves this token");
}

function isJsonObject(json: Json | null | undefined): json is { [key: string]: Json } {
  return typeof json === "object" && json !== null && !Array.isArray(json);
}
