// McpReactor: the `mcp` reactor — the built-in MCP client AND inbound MCP server as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). Four call shapes reach it, told apart ONCE
// at the `openPayload` boundary (the compiled `prelude.mcp.tools` / `prelude.mcp.serve` /
// `prelude.mcp.call` externals arrive as their qualified names on the wire; every other key is a minted
// tool's server-declared name):
//   - `listTools` (the `prelude.mcp.tools` external): list the server's tools and MINT one agent value
//     per tool — a `$tool` carrying the server-declared signature and, as its context, the server
//     DESCRIPTOR (`{url, auth}`; the auth sum — explicit headers or a named OAuth credential — rides
//     inside it and is dispatched at the TRANSPORT boundary, never here). The minting is the payload's
//     own `shapeResult`, built here from the call's ORIGINAL argument values — so a header value's
//     privacy markers survive into the minted tools (the wire to the transport reveals; the minted
//     values must not; an oauth credential NAME is not secret).
//   - `callTool` (a minted tool's call, an `external` target carrying that descriptor as `context`): the
//     caller's argument passes to the transport verbatim, the descriptor rides out-of-band.
//   - `directCall` (the `prelude.mcp.call` external): the STATIC counterpart of a minted tool's call —
//     a compiled external carries no context, so everything (`{url, auth, tool, arguments}`) rides in
//     the call's own argument. `arguments` is a `json` TREE; it lowers to the literal Json document at
//     dispatch (the same `jsonValueToJson` walk behind `json.stringify`, so a blob-backed string leaf
//     materialises), and the transport's reply lifts back LITERALLY into a `json` tree (`structuredContent`
//     as its tree, plain text as a `json_string`, a produced blob's `$ref` handle as a literal object
//     inside the tree — which `json.decode` with a `file`-typed shape then lifts into a handle).
//   - `serve` (the `prelude.mcp.serve` external): the INBOUND direction, mirroring the webhook reactor —
//     no transport at all. It mints an unguessable token (the public URL's capability), dispatches the
//     SUBSCRIBER once as an inner delegation carrying that URL, and converts every MCP `tools/call` to
//     that URL into an inner delegation of the named agent in the served tools record (resolved through
//     the shared `dispatchCallable`, so the callee validates — a mismatch surfaces as
//     `reflection.call_error` without ever failing the run). The call settles when the SUBSCRIBER
//     settles; a `terminate` from above cancels it and releases the token either way.
//
// A payload is a two-level sum — `serve | transport{listTools|callTool|directCall|recovered}` — so every
// serve-vs-transport lifecycle method dispatches that axis once, structurally. The transport-backed shapes
// own their in-flight calls durably as a status-only `mcp_instances` row (no argument is persisted) and
// recovery never re-runs, so a reloaded transport call's payload is the explicit `recovered` variant —
// nothing dispatch-shaped survives a restart by type. A `serve` call, by contrast, persists its endpoint
// payload in a separate `mcp_serve_instances` extension (token + tools record + its inner-delegation
// bridges) and survives a restart COMPLETELY, exactly like a webhook endpoint: there is no external process
// to reconcile with, the subscriber's inner delegation is durable core work, and the reload re-registers
// the token. Connections are the TRANSPORT's business (a lazy, descriptor-keyed cache), not a
// program-visible resource: a restart empties the cache and the next tool call reconnects — tools survive
// restarts. Every anticipated transport failure is a typed `throw[mcp.server_error]` (including a direct
// call's argument-lowering failure, completed as that throw at its own site); a bare `error` completion is
// an engine-invariant panic; a serve call's failures are the program's own (its subscriber panics like any
// callee).

import { randomBytes } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { CALL_ERROR, dispatchCallable } from "../engine/dynamic-dispatch.js";
import { jsonValueFromJson, jsonValueToJson, type StringReader } from "../engine/json-value.js";
import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import type { McpToolListing, McpTransport } from "../external/mcp-transport.js";
import type { DelegationId, SnapshotId } from "../ids.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import { jsonToSchema } from "../value/schema-json.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalTarget,
  type InnerDelivery,
  innerOutcomeAsCompletion,
  type LoadedCall,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** The reserved dispatch keys the compiled `prelude.mcp.*` externals arrive under — compared exactly
 *  here, at the payload boundary (tool names are server-scoped and never dotted like this, so they
 *  cannot collide). Past `openPayload` the call shapes are distinct payload variants, not key sniffs. */
const MCP_TOOLS_KEY = "prelude.mcp.tools";
const MCP_SERVE_KEY = "prelude.mcp.serve";
const MCP_CALL_KEY = "prelude.mcp.call";

/** A transport-backed mcp call — the built-in client's OUTBOUND side, told apart from a `serve` endpoint at
 *  the TOP level of `McpPayload` (see below) so every serve-vs-transport method dispatches that axis once,
 *  structurally. The four sub-shapes: a `listTools` listing (its descriptor from the call's original
 *  marker-bearing argument), a `callTool` dispatch (the tool's name, the descriptor from the minted tool's
 *  context, the caller's argument verbatim), a `directCall` (`{url, auth, tool, arguments}` all in the
 *  call's own argument), or `recovered` — a reloaded transport call, which by construction can never be
 *  re-dispatched (at-most-once; nothing dispatch-shaped is persisted for the transport shapes). */
type TransportCall =
  | {
      kind: "listTools";
      /** The `{url, auth}` descriptor with privacy markers intact — the transport gets a revealed
       *  copy, the minted tools get this one. */
      descriptor: Value;
    }
  | {
      kind: "callTool";
      tool: string;
      /** The minted tool's descriptor context; `null` only for a malformed target (no minted tool lacks
       *  one), which the transport rejects as the typed descriptor error. */
      descriptor: Value | null;
      argument: Value | null;
    }
  | {
      kind: "directCall";
      /** The `{url, auth}` descriptor assembled from the call's own argument (privacy markers intact —
       *  the transport gets a revealed copy at dispatch, like the other transport shapes). */
      descriptor: Value;
      /** The `tool` name value (a string leaf, possibly blob-backed) — read at dispatch, where the
       *  string reader is allowed to touch the store. */
      tool: Value | null;
      /** The `arguments` json tree, lowered to the literal Json document at dispatch. */
      argumentsTree: Value | null;
    }
  | { kind: "recovered" };

/** What an mcp call holds, a two-level sum whose TOP level is the serve-vs-transport axis every lifecycle
 *  method (dispatch / recover / abort / onDropCall / persistCallRow / loadCallRows) dispatches once: a
 *  `serve` endpoint (token + the served tools record — persisted, so the endpoint survives a restart; the
 *  subscriber is consumed by the one-time dispatch and never stored), or a `transport` call (its
 *  `TransportCall` sub-shape plus its optional ack decoder). */
type McpPayload =
  | {
      kind: "serve";
      /** The snapshot the call was dispatched against — persisted as the ext row's version pin
       *  (retention: a live endpoint keeps its snapshot undeletable, so the served agents stay
       *  resolvable). */
      snapshot: SnapshotId;
      token: string;
      /** The served tools record (key = the published tool name, value = the agent it dispatches). */
      tools: Value;
      subscriber: Value | null;
    }
  | {
      kind: "transport";
      call: TransportCall;
      /** The ONE ack-shaping seam (`AckDecodingPayload`, applied by the base at the wire-decode boundary):
       *  a `listTools` mints its toolbox from the raw listing, a `directCall` lifts the raw reply literally
       *  into a `json` tree; `callTool` / `recovered` omit it, so the base wire decoder runs. */
      decodeAck?: (raw: Json) => Value;
    };

/** The live endpoint's served tools, resolved on a reactor turn (values still engine `Value`s — the
 *  actor resolves each entry's metadata, the service lowers at the user-facing boundary). */
export type McpServeToolsOutcome =
  /** No live endpoint holds this token. */
  | { kind: "unknown" }
  /** The served record's entries, in stable (sorted) key order. */
  | { kind: "tools"; entries: Array<{ name: string; value: Value }> };

/** How one served `tools/call` ended, resolved to the waiting HTTP request. */
export type McpServeCallOutcome =
  /** No live endpoint holds this token. */
  | { kind: "unknown" }
  /** The endpoint exists but is winding down (cancelling, or its subscriber already settled). */
  | { kind: "gone" }
  /** The served record has no tool under the requested name. */
  | { kind: "unknownTool" }
  /** The agent returned; its result is the tool result. */
  | { kind: "result"; value: Value }
  /** The agent (or the dispatch boundary) threw a typed error — a schema violation is a
   *  `reflection.call_error`, the anticipated invalid-arguments case. */
  | { kind: "throw"; value: Value }
  /** The agent panicked (or its process failed) — the internal-error case. */
  | { kind: "error"; message: string };

/** The subscriber's reserved inner-call token; served tool calls use fresh `delivery:` tokens. */
const SUBSCRIBER_CALL = "subscriber";

export class McpReactor extends ExternalCallReactor<McpPayload> {
  readonly name: ReactorName = "mcp";

  /** The live serve endpoints: a URL token to the call serving it. Registered at dispatch / reload,
   *  released at drop — so an inbound MCP request resolves its call in O(1). */
  private readonly tokens = new Map<string, DelegationId>();
  /** The HTTP requests awaiting a served tool call's outcome, by inner-call token. In-memory only: a
   *  waiter that dies with the process simply never answers (the MCP caller retries); the delivery
   *  itself is durable. */
  private readonly waiters = new Map<string, (outcome: McpServeCallOutcome) => void>();
  private deliverySequence = 0;

  constructor(
    private readonly transport: McpTransport,
    /** The public base the minted serve URLs are formed under (`<baseUrl>/mcp/<token>`). */
    private readonly baseUrl: string,
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how a serve call's post-commit
     *  work (the subscriber dispatch, a synthesised completion) re-enters the transactional loop. */
    private readonly schedule: (work: () => void) => void,
    /** Reads a string leaf's content (inline, or a semantic-string blob through the store) — what a
     *  `directCall`'s json-tree lowering needs at dispatch. */
    private readonly readString: StringReader,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  // ─── the inbound serve entries (called on a scheduled reactor turn) ─────────────────────────────

  /** The tools a live endpoint serves, for `tools/list` (and the `initialize` liveness probe). A pure
   *  read — the actor resolves each entry's schema metadata outside the turn. */
  serveTools(token: string): McpServeToolsOutcome {
    const payload = this.servePayloadOf(token);
    if (payload === undefined) return { kind: "unknown" };
    const fields = payload.tools.kind === "record" ? payload.tools.fields : {};
    const entries: Array<{ name: string; value: Value }> = [];
    for (const name of Object.keys(fields).sort()) {
      const value = fields[name];
      if (value !== undefined) entries.push({ name, value });
    }
    return { kind: "tools", entries };
  }

  /** Convert one MCP `tools/call` into an inner delegation of the served record's agent. `resolve` is
   *  called exactly once — synchronously for a dead token / unknown tool / schema violation, post-commit
   *  with the agent's outcome otherwise. Runs inside a reactor turn, so the opened delegation commits
   *  with it. */
  serveCall(
    token: string,
    tool: string,
    argument: Value,
    resolve: (outcome: McpServeCallOutcome) => void,
  ): void {
    const delegation = this.tokens.get(token);
    const payload = this.servePayloadOf(token);
    if (delegation === undefined || payload === undefined) {
      resolve({ kind: "unknown" });
      return;
    }
    const fields = payload.tools.kind === "record" ? payload.tools.fields : {};
    // Own-key access, like the record prims: an inherited key (`toString`) must not read as a tool.
    const callable = Object.hasOwn(fields, tool) ? fields[tool] : undefined;
    if (callable === undefined) {
      resolve({ kind: "unknownTool" });
      return;
    }
    // Resolve the agent value through the shared dynamic dispatch: an agent / closure is delegated
    // directly (the delegation boundary then validates against the callee's own schema — the callee
    // validates); a `tool` entry validates against its runtime schema right here, so a violating call
    // is answered as invalid arguments without ever entering the engine.
    const dispatched = dispatchCallable(callable, argument);
    if ("error" in dispatched) {
      resolve({ kind: "throw", value: errorData(CALL_ERROR, dispatched.error) });
      return;
    }
    this.deliverySequence += 1;
    const call = `delivery:${this.deliverySequence}`;
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      call,
      dispatched.generics,
    );
    if (opened === null) {
      resolve({ kind: "gone" });
      return;
    }
    this.waiters.set(call, resolve);
  }

  /** The live `serve` payload behind a token — `undefined` for a dead token (dropping a stale index
   *  entry on the way, mirroring the webhook reactor's read). */
  private servePayloadOf(token: string): Extract<McpPayload, { kind: "serve" }> | undefined {
    const delegation = this.tokens.get(token);
    const payload = delegation === undefined ? undefined : this.payloadOf(delegation);
    if (delegation === undefined || payload === undefined || payload.kind !== "serve") {
      this.tokens.delete(token);
      return undefined;
    }
    return payload;
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(target: ExternalTarget, argument: Value | null): McpPayload {
    if (target.key === MCP_TOOLS_KEY) {
      const descriptor = descriptorOf(argument);
      const snapshot = target.snapshot;
      return {
        kind: "transport",
        call: { kind: "listTools", descriptor },
        // Mint the toolbox from the raw listing (decoded by the base wire decoder first) plus the call's
        // original privacy-marked descriptor, which the wire cannot carry.
        decodeAck: (raw) => mintToolbox(jsonToValue(raw), descriptor, snapshot),
      };
    }
    if (target.key === MCP_CALL_KEY) {
      const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
      return {
        kind: "transport",
        call: {
          kind: "directCall",
          descriptor: descriptorOf(argument),
          tool: fields.tool ?? null,
          argumentsTree: fields.arguments ?? null,
        },
        // Lift the transport's raw reply LITERALLY into the `json` tree the caller receives (total for any
        // server reply — a reserved `$`-key stays a plain tree key, exactly the `$ref`-inside-the-tree form
        // `json.decode` expects). Keeping hostile / quirky server Json off the wire decoder is why this
        // shapes here rather than through the generic decoder.
        decodeAck: (raw) => jsonValueFromJson(raw),
      };
    }
    if (target.key === MCP_SERVE_KEY) {
      const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
      return {
        kind: "serve",
        // 24 random bytes, base64url — the URL is the capability, so the token must be unguessable.
        token: randomBytes(24).toString("base64url"),
        snapshot: target.snapshot,
        tools: fields.tools ?? { kind: "record", fields: {} },
        subscriber: fields.subscriber ?? null,
      };
    }
    return {
      kind: "transport",
      call: { kind: "callTool", tool: target.key, descriptor: target.context ?? null, argument },
    };
  }

  protected dispatch(delegation: DelegationId, payload: McpPayload): void {
    if (payload.kind === "serve") {
      // Post-commit: activate the endpoint and hand the one-time subscriber dispatch back to the serial
      // loop (a dispatch is a side-effect slot — the inner delegation must open inside a turn).
      this.tokens.set(payload.token, delegation);
      const subscriber = payload.subscriber;
      payload.subscriber = null;
      this.schedule(() => this.startSubscriber(delegation, subscriber));
      return;
    }
    // Lowering to plain Json for the SDK reveals a secret header value (an MCP server is an allowed
    // sink, like an http auth header), unlike the user-facing API.
    const call = payload.call;
    switch (call.kind) {
      case "listTools":
        this.transport.dispatch({
          kind: "listTools",
          delegation,
          descriptor: valueToJson(call.descriptor, "reveal"),
        });
        return;
      case "callTool":
        this.transport.dispatch({
          kind: "callTool",
          delegation,
          tool: call.tool,
          descriptor: call.descriptor === null ? null : valueToJson(call.descriptor, "reveal"),
          argument: call.argument === null ? null : valueToJson(call.argument, "reveal"),
        });
        return;
      case "directCall":
        // Lowering the arguments tree may read a blob-backed string leaf, so the dispatch finishes
        // asynchronously; the transport call is fire-and-forget anyway.
        void this.dispatchDirectCall(delegation, call);
        return;
      case "recovered":
        // A reloaded transport call only ever goes through `recover` (at-most-once), so a recovered
        // payload reaching the dispatch seam is a runtime bug — fail loudly rather than fabricate a call.
        throw new Error(`mcp: refusing to dispatch recovered call ${delegation} (at-most-once)`);
    }
  }

  /** Finish a `directCall`'s dispatch: read the tool name, lower the arguments tree to its literal
   *  Json document (the `json.stringify` walk, so a blob-backed string leaf materialises), and hand
   *  the transport the SAME `callTool` operation a minted tool's call produces. The argument-lowering
   *  failure is program-anticipatable (a malformed tree), so it completes as the typed
   *  `throw[mcp.server_error]` DIRECTLY here — the same channel every other transport failure uses.
   *  That is why this reactor no longer overrides `escalateError`: a bare `error` completion stays an
   *  engine-invariant panic uniformly. */
  private async dispatchDirectCall(
    delegation: DelegationId,
    call: Extract<TransportCall, { kind: "directCall" }>,
  ): Promise<void> {
    let tool: string;
    let argumentDocument: Json | null;
    try {
      if (call.tool === null) throw new Error("mcp.call: the tool name is missing");
      tool = await this.readString(call.tool);
      argumentDocument =
        call.argumentsTree === null
          ? null
          : await jsonValueToJson(call.argumentsTree, this.readString);
    } catch (cause) {
      this.schedule(() =>
        this.complete({
          delegation,
          outcome: {
            kind: "throw",
            error: valueToJson(errorData(SERVER_ERROR, `mcp.call: ${messageOf(cause)}`), "reveal"),
          },
        }),
      );
      return;
    }
    // The call may have resolved (a cancel) while the tree was lowering; a dead call must not reach
    // the server. A cancel landing after this check races like any transport dispatch would — the
    // late completion is guarded at the base.
    if (this.payloadOf(delegation) === undefined) return;
    this.transport.dispatch({
      kind: "callTool",
      delegation,
      tool,
      descriptor: valueToJson(call.descriptor, "reveal"),
      argument: argumentDocument,
    });
  }

  /** The one-time subscriber dispatch (a reactor turn): delegate the subscriber value with the minted
   *  capability URL. Its settlement is the whole call's settlement (see `deliverInnerOutcome`). */
  private startSubscriber(delegation: DelegationId, subscriber: Value | null): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "serve") return; // resolved / cancelled meanwhile
    if (subscriber === null) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: "mcp.serve: the subscriber is missing" },
      });
      return;
    }
    const url: Value = {
      kind: "record",
      fields: { url: { kind: "string", value: `${this.baseUrl}/mcp/${payload.token}` } },
    };
    const dispatched = dispatchCallable(subscriber, url);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: `mcp.serve: the subscriber is ${dispatched.error}` },
      });
      return;
    }
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      SUBSCRIBER_CALL,
      dispatched.generics,
    );
    if (opened === null) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: "mcp.serve: the call cannot accept work" },
      });
    }
  }

  /** A settled inner delegation (only a `serve` call opens them). The subscriber's outcome IS the
   *  call's outcome — feed it back as the transport completion on a fresh turn; a served tool call's
   *  outcome resolves its waiting HTTP request (a waiter lost to a restart just drops it — the MCP
   *  caller retries). */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    if (delivery.call === SUBSCRIBER_CALL) {
      this.schedule(() =>
        this.complete({
          delegation: delivery.delegation,
          outcome: innerOutcomeAsCompletion(delivery.outcome),
        }),
      );
      return;
    }
    const waiter = this.waiters.get(delivery.call);
    if (waiter === undefined) return;
    this.waiters.delete(delivery.call);
    switch (delivery.outcome.kind) {
      case "result":
        waiter({ kind: "result", value: delivery.outcome.value });
        return;
      case "throw":
        waiter({ kind: "throw", value: delivery.outcome.value });
        return;
      case "error":
        waiter({ kind: "error", message: delivery.outcome.message });
        return;
      case "cancelled":
        waiter({ kind: "gone" });
        return;
    }
  }

  protected recover(delegation: DelegationId): void {
    // A reloaded serve endpoint just re-registers its token — no external process to reconcile with
    // (the subscriber's inner delegation is durable core work resuming on its own); a transport call
    // reconciles at-most-once through the transport.
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") {
      this.tokens.set(payload.token, delegation);
      return;
    }
    this.transport.recover(delegation);
  }

  protected abort(delegation: DelegationId): void {
    // A serve call's cancel has no transport half: deactivate the endpoint and confirm on a fresh turn
    // (the children — the subscriber, in-flight served calls — drain through the base's cancel cascade).
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") {
      this.tokens.delete(payload.token);
      this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
      return;
    }
    this.transport.abort(delegation);
  }

  /** A serve call resolved: release its token (the drop hook covers every resolution path at once). */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") this.tokens.delete(payload.token);
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<McpPayload>): Promise<void> {
    // A transport call persists only its status (at-most-once; it opens no inner delegations, so its
    // bridges are empty by construction — the status-only `mcp_instances` row); a serve call persists its
    // whole endpoint extension (`mcp_serve_instances`: token + tools + its inner-delegation bridges), so a
    // restart re-registers it.
    await tx.mcp.putMcpInstance({
      instanceId: row.instance,
      status: row.status,
      serve:
        row.payload.kind === "serve"
          ? {
              snapshotId: row.payload.snapshot,
              token: row.payload.token,
              tools: row.payload.tools,
              relays: row.relays,
              innerCalls: row.innerCalls,
            }
          : null,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<McpPayload>>> {
    return (await loader.mcp.instances()).map((row) => ({
      delegation: row.delegation,
      instance: row.instance,
      caller: row.caller,
      run: row.run,
      status: row.status,
      // A row with a serve extension reloads as the live endpoint (the subscriber was dispatched exactly
      // once at the original open; never re-dispatched), carrying its inner-delegation bridges. A
      // transport row (no serve extension) reloads as `recovered`: nothing dispatch-shaped is persisted
      // for it, so the payload says so by type and its bridges are empty.
      payload:
        row.serve === null
          ? { kind: "transport", call: { kind: "recovered" } }
          : {
              kind: "serve",
              token: row.serve.token,
              snapshot: row.serve.snapshotId,
              tools: row.serve.tools,
              subscriber: null,
            },
      relays: row.serve?.relays ?? [],
      innerCalls: row.serve?.innerCalls ?? [],
    }));
  }

  override reset(): void {
    super.reset();
    this.tokens.clear();
    // Waiters are in-process HTTP requests; a reset (poisoned commit) makes their calls unresolvable.
    for (const waiter of this.waiters.values()) waiter({ kind: "gone" });
    this.waiters.clear();
  }
}

/** The domain error ctor every anticipated mcp transport failure throws (`prelude/mcp.ktr` declares it). */
const SERVER_ERROR = "prelude.mcp.server_error";

/** The `{url, auth}` descriptor of a `tools` call, from its original (marker-bearing) argument. */
function descriptorOf(argument: Value | null): Value {
  if (argument === null || argument.kind !== "record") {
    return { kind: "record", fields: {} };
  }
  const fields: Record<string, Value> = Object.create(null);
  if (argument.fields.url !== undefined) fields.url = argument.fields.url;
  if (argument.fields.auth !== undefined) fields.auth = argument.fields.auth;
  return { kind: "record", fields };
}

/** Mint the toolbox for a settled `tools` listing: one agent value per server tool, carrying the
 *  server-declared signature and — as its context — the DESCRIPTOR from the call's original argument
 *  (`{url, auth}` with privacy markers intact; the transport's revealed copy is never minted). */
function mintToolbox(listing: Value, descriptor: Value, snapshot: SnapshotId): Value {
  const fields: Record<string, Value> = Object.create(null);
  for (const tool of listingsOf(listing)) {
    fields[tool.name] = {
      kind: "tool",
      reactor: "mcp",
      name: tool.name,
      description: tool.description,
      context: descriptor,
      snapshot,
      inputSchema: jsonToSchema(tool.inputSchema),
      ...(tool.outputSchema !== undefined ? { outputSchema: jsonToSchema(tool.outputSchema) } : {}),
    };
  }
  return { kind: "record", fields };
}

/** The transport's `{ tools: [...] }` listing, decoded back out of the completion value. A malformed
 *  shape is transport drift, not a program error — fail loudly (the substrate surfaces it). */
function listingsOf(value: Value): McpToolListing[] {
  if (value.kind !== "record" || value.fields.tools?.kind !== "array") {
    throw new Error("mcp: the tools completion did not carry a { tools: [...] } listing");
  }
  const listings: McpToolListing[] = [];
  for (const entry of value.fields.tools.elements) {
    if (entry.kind !== "record") continue;
    const name = entry.fields.name;
    const description = entry.fields.description;
    if (name?.kind !== "string") continue;
    listings.push({
      name: name.value,
      description: description?.kind === "string" ? description.value : "",
      inputSchema:
        entry.fields.inputSchema === undefined
          ? {}
          : valueToJson(entry.fields.inputSchema, "reveal"),
      ...(entry.fields.outputSchema !== undefined
        ? { outputSchema: valueToJson(entry.fields.outputSchema, "reveal") }
        : {}),
    });
  }
  return listings;
}
