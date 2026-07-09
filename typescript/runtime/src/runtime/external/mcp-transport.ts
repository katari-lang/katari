// The mcp transport: the `mcp` reactor's outbound side — a built-in MCP client over the official SDK
// (in-runtime, like the http transport's fetch; nothing for the user to install). Two operations reach
// it, already told apart by the reactor (the `McpCall` union): `listTools` (the `prelude.mcp.tools`
// external — list the server's tools, so the reactor can mint one agent value per tool) and `callTool`
// (a minted tool's delegate, carrying its server descriptor and the caller's argument verbatim).
//
// Connections are NOT a user-visible resource: a tool carries its server DESCRIPTOR (url + headers),
// and this transport keeps a lazy client cache keyed by it — connecting on first use, reusing across
// calls, evicting on failure so the next call reconnects. A runtime restart just empties the cache;
// tool values that survived in scopes reconnect transparently on their next call.
//
// Every anticipated failure — the server rejecting a connect, a tool reporting `isError`, a transport
// drop — completes as a TYPED throw of `prelude.mcp.server_error`, matching the effect the
// `prelude.mcp` externals declare; a Katari handler catches it like any stdlib throw.

import type { Json } from "@katari-lang/types";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { DelegationId } from "../ids.js";

/** One mcp operation to perform, already lowered to plain Json (secret header values revealed at the
 *  reactor boundary — an MCP server is an allowed sink, like an http auth header). Each variant carries
 *  its `{ url, headers }` server descriptor itself: a listing's comes from the call's argument, a tool
 *  call's from the minted tool's context — resolved reactor-side, so this seam never sniffs shapes. A
 *  tool call's `descriptor` is `null` only for a malformed target (no minted tool lacks one); the
 *  dispatch then fails as the typed descriptor error. */
export type McpCall =
  | { kind: "listTools"; delegation: DelegationId; descriptor: Json }
  | {
      kind: "callTool";
      delegation: DelegationId;
      tool: string;
      descriptor: Json | null;
      argument: Json | null;
    };

/** One listed tool, as the reactor needs it to mint an agent value: the server-declared name /
 *  description / schemas (schemas as plain JSON Schema documents). */
export interface McpToolListing {
  name: string;
  description: string;
  inputSchema: Json;
  outputSchema?: Json;
}

/** The outcome of one dispatched mcp call: a `result` (→ delegateAck; a listing completes with
 *  `{ tools: McpToolListing[] }`, which the reactor transforms into the minted toolbox), a `throw` (a
 *  typed `prelude.mcp.server_error` payload — the anticipated failure channel), an `error` (an
 *  engine-level invariant violation → a panic), or a `cancelled` confirmation (after an `abort`). */
export interface McpCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "throw"; error: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

export interface McpTransport {
  /** Register the sink the reactor consumes completions through (called once at wiring). */
  onComplete(sink: (completion: McpCompletion) => void): void;
  /** Perform one operation — always means "run it" (fire-and-forget; the outcome arrives via the sink). */
  dispatch(call: McpCall): void;
  /** Reconcile a reloaded in-flight call (at-most-once; never re-runs): a call this transport still has
   *  running is left alone (a warm reset); one whose process is gone fails as a typed `server_error` —
   *  the caller catches and retries, and the retry reconnects through the descriptor cache. */
  recover(delegation: DelegationId): void;
  /** Abort an in-flight call; its `cancelled` (or a racing real) completion confirms the teardown. */
  abort(delegation: DelegationId): void;
  /** Tear the transport down (actor disposal): close every cached client, deliver nothing after. */
  close(): void;
}

/** The seam default: no mcp client configured, so dispatching one is an error (fails loudly, like the
 *  http stub — a test that reaches mcp by accident is caught rather than hitting a real server). */
export class StubMcpTransport implements McpTransport {
  onComplete(): void {}
  dispatch(call: McpCall): void {
    throw new Error(`mcp transport not configured (call ${call.delegation})`);
  }
  recover(delegation: DelegationId): void {
    throw new Error(`mcp transport not configured (recovering call ${delegation})`);
  }
  abort(): void {}
  close(): void {}
}

/** The blob-producer seam: store `bytes` as a project blob owned by `delegation`'s call instance and
 *  return its `$ref` handle Json (the wire form the reactor's decode lifts back into a `file` value),
 *  or `null` when the call is already gone (the block then degrades to its text placeholder). Wired by
 *  the host (see the facade); absent — tests, a stub deployment — every binary block degrades. */
export type McpBlobProducer = (
  delegation: DelegationId,
  bytes: Uint8Array,
  contentType: string | undefined,
) => Promise<Json | null>;

/** Shape one successful tool call's SDK result into the completion's Json value:
 *   - binary content blocks (image / audio: base64 `data` + `mimeType`) become project blobs via
 *     `produceBlob`, and the result is `{ text, files }` — each handle lifts into a `file` value at
 *     the reactor's decode, so a Katari caller (or an AI loop) receives real files;
 *   - otherwise `structuredContent` rides through as the value it is;
 *   - otherwise the text blocks, joined, are the result (what an AI loop renders back to the model).
 *  A binary block with no producer — or whose call vanished mid-produce — degrades to its
 *  `(<type> content)` placeholder line, the pre-bridge behaviour. */
export async function resolveToolResult(
  // The index signature admits every member of the SDK's result union (the legacy `{toolResult}` shape
  // carries neither `content` nor `structuredContent`; it degrades to the empty text result).
  result: { structuredContent?: unknown; content?: unknown; [key: string]: unknown },
  produceBlob: McpBlobProducer | undefined,
  delegation: DelegationId,
): Promise<Json> {
  const blocks = Array.isArray(result.content) ? result.content : [];
  const texts: string[] = [];
  const files: Json[] = [];
  for (const block of blocks) {
    const classified = classifyContentBlock(block);
    switch (classified.kind) {
      case "shapeless":
        continue;
      case "text":
        texts.push(classified.text);
        continue;
      case "binary": {
        if (produceBlob !== undefined) {
          const handle = await produceBlob(
            delegation,
            new Uint8Array(Buffer.from(classified.data, "base64")),
            classified.contentType,
          );
          if (handle !== null) {
            files.push(handle);
            continue;
          }
        }
        texts.push(classified.placeholder);
        continue;
      }
      case "other":
        texts.push(classified.placeholder);
        continue;
    }
  }
  if (files.length > 0) {
    return { text: texts.join("\n"), files };
  }
  if (result.structuredContent !== undefined) {
    return result.structuredContent as Json;
  }
  return texts.join("\n");
}

/** One SDK content block, classified once for both consumers (a result's shaping, an error's text): its
 *  text, a binary (image / audio) payload to bridge into a blob, or the `(<type> content)` placeholder any
 *  other typed block degrades to. A shapeless block (no string `type`) carries nothing renderable. */
type ClassifiedContentBlock =
  | { kind: "text"; text: string }
  | { kind: "binary"; data: string; contentType: string | undefined; placeholder: string }
  | { kind: "other"; placeholder: string }
  | { kind: "shapeless" };

function classifyContentBlock(block: unknown): ClassifiedContentBlock {
  if (typeof block !== "object" || block === null) return { kind: "shapeless" };
  const entry: { type?: unknown; text?: unknown; data?: unknown; mimeType?: unknown } = block;
  if (entry.type === "text" && typeof entry.text === "string") {
    return { kind: "text", text: entry.text };
  }
  if (typeof entry.type !== "string") return { kind: "shapeless" };
  const placeholder = `(${entry.type} content)`;
  if ((entry.type === "image" || entry.type === "audio") && typeof entry.data === "string") {
    return {
      kind: "binary",
      data: entry.data,
      contentType: typeof entry.mimeType === "string" ? entry.mimeType : undefined,
      placeholder,
    };
  }
  return { kind: "other", placeholder };
}

/** The wire form of a typed `prelude.mcp.server_error` throw (decoded back into the data value at the
 *  reactor base). */
function serverError(message: string): Json {
  return { $constructor: "prelude.mcp.server_error", value: { message } };
}

/** A server descriptor, read out of a lowered `{ url, headers }` record. */
interface Descriptor {
  url: string;
  headers: Record<string, string>;
}

/** The production transport: the official MCP SDK behind a lazy, descriptor-keyed client cache.
 *  Streamable HTTP first, one fallback to HTTP+SSE, so both generations of servers connect with the
 *  same `url`. A failed call evicts its cache entry, so the next call reconnects. */
export class SdkMcpTransport implements McpTransport {
  private sink: ((completion: McpCompletion) => void) | null = null;
  /** Lazy clients by descriptor key. The Promise is cached (not the client) so concurrent first calls
   *  share one connect; a rejected connect evicts itself, so nothing caches a dead entry. */
  private readonly clients = new Map<string, Promise<Client>>();
  private readonly controllers = new Map<DelegationId, AbortController>();

  /** `produceBlob` bridges a tool result's binary content into project blobs (see `McpBlobProducer`);
   *  without it every binary block degrades to its text placeholder. */
  constructor(private readonly produceBlob?: McpBlobProducer) {}

  onComplete(sink: (completion: McpCompletion) => void): void {
    this.sink = sink;
  }

  dispatch(call: McpCall): void {
    const controller = new AbortController();
    this.controllers.set(call.delegation, controller);
    void this.perform(call, controller.signal)
      .then((outcome) => this.emit({ delegation: call.delegation, outcome }))
      .finally(() => this.controllers.delete(call.delegation));
  }

  recover(delegation: DelegationId): void {
    // Never re-run (at-most-once). The typed throw is catchable; a katari-level retry reconnects
    // through the descriptor cache, so nothing is permanently stale.
    if (!this.controllers.has(delegation)) {
      this.emit({
        delegation,
        outcome: {
          kind: "throw",
          error: serverError("mcp call interrupted by a runtime restart"),
        },
      });
    }
  }

  abort(delegation: DelegationId): void {
    const controller = this.controllers.get(delegation);
    if (controller !== undefined) {
      controller.abort();
      return;
    }
    this.emit({ delegation, outcome: { kind: "cancelled" } });
  }

  close(): void {
    for (const controller of this.controllers.values()) controller.abort();
    this.controllers.clear();
    for (const pending of this.clients.values()) {
      void pending.then((client) => client.close()).catch(() => {});
    }
    this.clients.clear();
    this.sink = null;
  }

  private emit(completion: McpCompletion): void {
    this.sink?.(completion);
  }

  /** Run one operation. Any anticipated failure — a rejected connect, a server-reported tool error, a
   *  dropped transport — is the typed `server_error` throw; the descriptor's cache entry is evicted so
   *  the next call reconnects fresh. */
  private async perform(call: McpCall, signal: AbortSignal): Promise<McpCompletion["outcome"]> {
    let descriptor: Descriptor | null = null;
    try {
      descriptor = readDescriptor(call.descriptor);
      switch (call.kind) {
        case "listTools":
          return { kind: "result", value: await this.listTools(descriptor) };
        case "callTool":
          return await this.callTool(call.delegation, descriptor, call.tool, call.argument, signal);
      }
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") {
        return { kind: "cancelled" };
      }
      // The connection may be the broken part — evict so the next call re-establishes it.
      if (descriptor !== null) this.clients.delete(descriptorKey(descriptor));
      return {
        kind: "throw",
        error: serverError(error instanceof Error ? error.message : String(error)),
      };
    }
  }

  private async listTools(descriptor: Descriptor): Promise<Json> {
    const { tools } = await (await this.clientFor(descriptor)).listTools();
    const listings: Json[] = tools.map((tool) => ({
      name: tool.name,
      description: tool.description ?? "",
      inputSchema: (tool.inputSchema ?? {}) as Json,
      ...(tool.outputSchema !== undefined ? { outputSchema: tool.outputSchema as Json } : {}),
    }));
    return { tools: listings };
  }

  private async callTool(
    delegation: DelegationId,
    descriptor: Descriptor,
    name: string,
    argument: Json | null,
    signal: AbortSignal,
  ): Promise<McpCompletion["outcome"]> {
    const toolArguments =
      argument !== null && typeof argument === "object" && !Array.isArray(argument)
        ? { ...argument }
        : {};
    const result = await (await this.clientFor(descriptor)).callTool(
      { name, arguments: toolArguments },
      undefined,
      { signal },
    );
    if (result.isError === true) {
      // The server reported the tool failing — the anticipated error path, typed for a Katari handler
      // (or an AI loop feeding it back to the model). The connection itself is fine: keep it cached.
      return { kind: "throw", error: serverError(contentText(result.content)) };
    }
    // Text / structured content ride through; binary content becomes project blobs (see
    // `resolveToolResult`), so an image-returning tool hands the caller real `file` values.
    return {
      kind: "result",
      value: await resolveToolResult(result, this.produceBlob, delegation),
    };
  }

  /** The cached client for a descriptor, connecting on first use. Streamable HTTP first, one fallback
   *  to HTTP+SSE; both failing evicts and reports the streamable error (the current protocol's). */
  private clientFor(descriptor: Descriptor): Promise<Client> {
    const key = descriptorKey(descriptor);
    const cached = this.clients.get(key);
    if (cached !== undefined) return cached;
    const requestInit =
      Object.keys(descriptor.headers).length > 0 ? { headers: descriptor.headers } : undefined;
    const attempt = async (kind: "streamable" | "sse"): Promise<Client> => {
      const client = new Client({ name: "katari-runtime", version: "0.1.0" });
      const target = new URL(descriptor.url);
      await client.connect(
        kind === "streamable"
          ? new StreamableHTTPClientTransport(target, { requestInit })
          : new SSEClientTransport(target, { requestInit }),
      );
      return client;
    };
    const pending = attempt("streamable")
      .catch(async (streamableError) => {
        try {
          return await attempt("sse");
        } catch {
          throw streamableError;
        }
      })
      .catch((error) => {
        // A failed connect evicts itself, so the next call retries instead of reusing the rejection.
        this.clients.delete(key);
        throw error;
      });
    this.clients.set(key, pending);
    return pending;
  }
}

/** A stable cache key for a server descriptor (headers key-sorted so ordering never splits entries). */
function descriptorKey(descriptor: Descriptor): string {
  const headers = Object.keys(descriptor.headers)
    .sort()
    .map((name) => `${name}:${descriptor.headers[name]}`)
    .join("\n");
  return `${descriptor.url}\n${headers}`;
}

/** Read a `{ url, headers }` descriptor out of a call's lowered Json descriptor. */
function readDescriptor(source: Json | null): Descriptor {
  if (source === null || typeof source !== "object" || Array.isArray(source)) {
    throw new Error("mcp: expected a { url, headers } descriptor");
  }
  const url = source.url;
  if (typeof url !== "string") {
    throw new Error('mcp: the descriptor\'s "url" must be a string');
  }
  const headers: Record<string, string> = {};
  const rawHeaders = source.headers;
  if (rawHeaders !== null && typeof rawHeaders === "object" && !Array.isArray(rawHeaders)) {
    for (const [name, value] of Object.entries(rawHeaders)) {
      if (typeof value === "string") headers[name] = value;
    }
  }
  return { url, headers };
}

/** The text of a tool result's content blocks, joined (non-text blocks noted by their placeholder). */
function contentText(content: unknown): string {
  if (!Array.isArray(content)) return "";
  const parts: string[] = [];
  for (const block of content) {
    const classified = classifyContentBlock(block);
    if (classified.kind === "text") parts.push(classified.text);
    else if (classified.kind !== "shapeless") parts.push(classified.placeholder);
  }
  return parts.join("\n");
}
