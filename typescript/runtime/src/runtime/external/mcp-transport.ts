// The mcp transport: the `mcp` reactor's outbound side — a built-in MCP client over the official SDK
// (in-runtime, like the http transport's fetch; nothing for the user to install). Two operations reach
// it, already told apart by the reactor (the `McpCall` union): `listTools` (the `prelude.mcp.tools`
// external — list the server's tools, so the reactor can mint one agent value per tool) and `callTool`
// (a minted tool's delegate, carrying its server descriptor and the caller's argument verbatim).
//
// Connections are NOT a user-visible resource: a tool carries its server DESCRIPTOR (url + auth),
// and this transport keeps a lazy client cache keyed by it — connecting on first use, reusing across
// calls, evicting on failure so the next call reconnects. A runtime restart just empties the cache;
// tool values that survived in scopes reconnect transparently on their next call.
//
// Auth is a SUM riding inside the descriptor (the `prelude.mcp.auth` data union, arriving as its
// `$constructor` wire tag): `headers` sends the given headers on every request (anonymous access is
// the empty map), `oauth` names a stored credential — the SDK transport then authenticates through a
// store-backed `OAuthClientProvider` (see `mcp-oauth.ts`), which injects the access token and writes
// refreshed tokens back. The cache key carries the auth IDENTITY (the header map, or the credential
// NAME — never token material).
//
// Every anticipated failure — the server rejecting a connect, a tool reporting `isError`, a transport
// drop — completes as a TYPED throw of `prelude.mcp.server_error`, matching the effect the
// `prelude.mcp` externals declare; a Katari handler catches it like any stdlib throw. A dead OAuth
// credential (missing, unreadable, or rejected beyond refresh) is the distinct
// `prelude.mcp.auth_error` — retrying cannot fix it, a human re-running `katari mcp login` can.

import type { Json } from "@katari-lang/types";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { SSEClientTransport } from "@modelcontextprotocol/sdk/client/sse.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import type { DelegationId } from "../ids.js";
import {
  loadStoredCredential,
  McpAuthError,
  type McpCredentialStore,
  StoredMcpOAuthProvider,
} from "./mcp-oauth.js";

/** One mcp operation to perform, already lowered to plain Json (secret header values revealed at the
 *  reactor boundary — an MCP server is an allowed sink, like an http auth header). Each variant carries
 *  its `{ url, auth }` server descriptor itself: a listing's comes from the call's argument, a tool
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

/** The wire form of the typed `prelude.mcp.auth_error` throw — the OAuth credential lifecycle failure
 *  a retry cannot fix (as opposed to `server_error`, whose contract IS "retry reconnects"). */
function authError(message: string): Json {
  return { $constructor: "prelude.mcp.auth_error", value: { message } };
}

/** The descriptor's auth sum, decoded from its `$constructor` wire tag: explicit request headers, or
 *  a named stored OAuth credential (the name is identity, not secret material). */
type DescriptorAuth =
  | { kind: "headers"; headers: Record<string, string> }
  | { kind: "oauth"; name: string };

/** A server descriptor, read out of a lowered `{ url, auth }` record. */
interface Descriptor {
  url: string;
  auth: DescriptorAuth;
}

/** What the host wires into an `SdkMcpTransport` (both parts optional so tests and stub deployments
 *  can run without them, degrading loudly at the exact feature that needs the missing part). */
export interface SdkMcpTransportDependencies {
  /** Bridges a tool result's binary content into project blobs (see `McpBlobProducer`); without it
   *  every binary block degrades to its text placeholder. */
  produceBlob?: McpBlobProducer;
  /** Resolves `oauth`-variant descriptors to stored credentials (see `McpCredentialStore`); without
   *  it every `oauth` dispatch fails as the typed `auth_error`. */
  credentials?: McpCredentialStore;
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
  private readonly produceBlob?: McpBlobProducer;
  private readonly credentials?: McpCredentialStore;

  constructor(dependencies: SdkMcpTransportDependencies = {}) {
    this.produceBlob = dependencies.produceBlob;
    this.credentials = dependencies.credentials;
  }

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
   *  dropped transport — is the typed `server_error` throw; a dead OAuth credential (missing, or the
   *  SDK's `UnauthorizedError` after refresh failed) is the typed `auth_error` instead. Either way the
   *  descriptor's cache entry is evicted so the next call starts fresh — after `auth_error`, that next
   *  call picks up whatever a re-run `katari mcp login` stored. */
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
      if (error instanceof McpAuthError || error instanceof UnauthorizedError) {
        return { kind: "throw", error: authError(error.message) };
      }
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
    const attempt = async (kind: "streamable" | "sse"): Promise<Client> => {
      const options = await this.connectionOptions(descriptor.auth);
      const client = new Client({ name: "katari-runtime", version: "0.1.0" });
      const target = new URL(descriptor.url);
      await client.connect(
        kind === "streamable"
          ? new StreamableHTTPClientTransport(target, options)
          : new SSEClientTransport(target, options),
      );
      return client;
    };
    const pending = attempt("streamable")
      .catch(async (streamableError) => {
        // A dead credential fails identically over SSE, so the fallback would only repeat the same
        // typed failure with a laggier path — rethrow the honest error instead.
        if (
          streamableError instanceof McpAuthError ||
          streamableError instanceof UnauthorizedError
        ) {
          throw streamableError;
        }
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

  /** The SDK transport options one auth variant needs: explicit headers ride as `requestInit`, an
   *  OAuth credential becomes a store-backed `authProvider` (loaded HERE, so a missing credential is
   *  the typed `auth_error` before any network I/O). The option shape is the common subset both the
   *  streamable and the SSE transports accept. */
  private async connectionOptions(
    auth: DescriptorAuth,
  ): Promise<{ requestInit?: RequestInit; authProvider?: StoredMcpOAuthProvider }> {
    switch (auth.kind) {
      case "headers":
        return Object.keys(auth.headers).length > 0
          ? { requestInit: { headers: auth.headers } }
          : {};
      case "oauth": {
        const store = this.credentials;
        if (store === undefined) {
          throw new McpAuthError(
            "this runtime has no OAuth credential store configured, so mcp.oauth(...) cannot resolve a credential",
          );
        }
        // Pre-flight: fail a missing credential as the typed auth_error BEFORE building any SDK
        // machinery. The provider then reads the credential THROUGH the store on each use, so a
        // credential a re-login replaced is picked up by a warm (transport-cached) provider rather than
        // being served — and refreshed off — stale.
        await loadStoredCredential(auth.name, store);
        return { authProvider: new StoredMcpOAuthProvider(auth.name, store) };
      }
    }
  }
}

/** A stable cache key for a server descriptor: the url plus the auth IDENTITY — the key-sorted header
 *  map, or the OAuth credential's name (never its token material, which rotates under refresh). The
 *  variant tag keeps the two families disjoint by construction. */
function descriptorKey(descriptor: Descriptor): string {
  const auth = descriptor.auth;
  switch (auth.kind) {
    case "headers": {
      const headers = Object.keys(auth.headers)
        .sort()
        .map((name) => `${name}:${auth.headers[name]}`)
        .join("\n");
      return `${descriptor.url}\nheaders\n${headers}`;
    }
    case "oauth":
      return `${descriptor.url}\noauth\n${auth.name}`;
  }
}

/** Read a `{ url, auth }` descriptor out of a call's lowered Json descriptor. */
function readDescriptor(source: Json | null): Descriptor {
  if (source === null || typeof source !== "object" || Array.isArray(source)) {
    throw new Error("mcp: expected a { url, auth } descriptor");
  }
  const url = source.url;
  if (typeof url !== "string") {
    throw new Error('mcp: the descriptor\'s "url" must be a string');
  }
  return { url, auth: readDescriptorAuth(source.auth) };
}

/** Decode the descriptor's auth sum from its wire form — the `$constructor`-tagged `data` value the
 *  program built (`mcp.headers(...)` / `mcp.oauth(...)`). This is the ONE place the tag is dispatched
 *  on; past here the variants are distinct union members. A malformed shape is wire drift, reported as
 *  the typed descriptor error (the catch in `perform` makes it a `server_error` throw). */
function readDescriptorAuth(source: Json | undefined): DescriptorAuth {
  if (
    source === null ||
    source === undefined ||
    typeof source !== "object" ||
    Array.isArray(source)
  ) {
    throw new Error(
      'mcp: the descriptor\'s "auth" must be an mcp.headers(...) or mcp.oauth(...) value',
    );
  }
  const fieldsSource = source.value;
  const fields =
    fieldsSource !== null && typeof fieldsSource === "object" && !Array.isArray(fieldsSource)
      ? fieldsSource
      : {};
  switch (source.$constructor) {
    case "prelude.mcp.headers": {
      const headers: Record<string, string> = {};
      const rawValues = fields.values;
      if (rawValues !== null && typeof rawValues === "object" && !Array.isArray(rawValues)) {
        for (const [name, value] of Object.entries(rawValues)) {
          if (typeof value === "string") headers[name] = value;
        }
      }
      return { kind: "headers", headers };
    }
    case "prelude.mcp.oauth": {
      const name = fields.name;
      if (typeof name !== "string" || name === "") {
        throw new Error("mcp: an mcp.oauth(...) auth value must carry its credential name");
      }
      return { kind: "oauth", name };
    }
    default:
      throw new Error(
        'mcp: the descriptor\'s "auth" must be an mcp.headers(...) or mcp.oauth(...) value',
      );
  }
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
