// McpReactor: the `mcp` reactor — the built-in MCP client AND inbound MCP server as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). Four call shapes reach it, told apart ONCE
// at the `openPayload` boundary (the compiled `prelude.mcp.provide` / `prelude.mcp.serve` /
// `prelude.mcp.call` externals arrive as their qualified names on the wire; every other key is a minted
// tool's server-declared name):
//   - `provide` (the `prelude.mcp.provide` external): a SCOPED provider (the `runST` shape). It lists the
//     server ONCE (an internal transport `listTools`, keyed by a side `listing` delegation so its completion
//     never settles the provide call), MINTS one agent value per tool — a `$tool` carrying the server
//     signature and, as its context, the server DESCRIPTOR plus this provide's runtime SCOPE identity — and
//     dispatches the CONTINUATION as an inner delegation receiving `{ value: toolbox }`. The whole call
//     settles with the continuation's outcome (the serve/webhook `innerOutcomeAsCompletion` template). While
//     the provide is live the scope is registered; a tool call carrying it proceeds on the same transport
//     path a listing-minted tool always did; when the provide settles or cancels the scope closes — the
//     descriptor's cached client is evicted and any later call carrying that scope is rejected as a typed
//     `server_error` (the runtime backstop for the dynamic-URL covariance hole; the type system rules out
//     the rest).
//   - `callTool` (a minted tool's call, an `external` target carrying `{ descriptor, scope }` as `context`):
//     the caller's argument passes to the transport verbatim; the descriptor rides out-of-band; the scope is
//     checked live first (a closed scope is the typed `server_error` backstop).
//   - `directCall` (the `prelude.mcp.call` external): the STATIC counterpart of a minted tool's call —
//     a compiled external carries no context, so everything (`{url, auth, tool, arguments}`) rides in
//     the call's own argument. It is scope-gated too, but carries no scope id: it must belong to a LIVE
//     provide of the same descriptor (a generated binding sits inside `with_tools`'s provide), else the
//     typed `server_error` names the missing provide. `arguments` is a `json` TREE; it lowers to the literal
//     Json document at dispatch (the same `jsonValueToJson` walk behind `json.stringify`, so a blob-backed
//     string leaf materialises), and the transport's reply lifts back LITERALLY into a `json` tree
//     (`structuredContent` as its tree, plain text as a `json_string`, a produced blob's `$ref` handle as a
//     literal object inside the tree — which `json.decode` with a `file`-typed shape then lifts into a handle).
//   - `serve` (the `prelude.mcp.serve` external): the INBOUND direction, mirroring the webhook reactor —
//     no transport at all. It mints an unguessable token (the public URL's capability), dispatches the
//     SUBSCRIBER once as an inner delegation carrying that URL, and converts every MCP `tools/call` to
//     that URL into an inner delegation of the named agent in the served tools record (resolved through
//     the shared `dispatchCallable`, so the callee validates — a mismatch surfaces as
//     `reflection.call_error` without ever failing the run). The call settles when the SUBSCRIBER
//     settles; a `terminate` from above cancels it and releases the token either way.
//
// A payload is a three-way sum — `provide | serve | transport{callTool|directCall|recovered}` — so every
// lifecycle method dispatches that axis once, structurally. `provide` and `serve` persist their endpoint
// payloads in the sibling subtype extensions (`mcp_provide_instances` / `mcp_serve_instances`: a
// provide's scope id + descriptor + still-listing continuation + inner-delegation bridges; a serve's token
// + tools + bridges) and survive a restart COMPLETELY (re-registering the scope / token, the inner
// delegation resuming as durable core work). The transport-backed shapes own their in-flight calls durably
// as a status-only `mcp_instances` row (no argument is persisted) and recovery never re-runs, so a reloaded
// transport call's payload is the explicit `recovered` variant — nothing dispatch-shaped survives a restart
// by type. Connections are the TRANSPORT's business (a lazy, descriptor-keyed cache), not a program-visible
// resource: a restart empties the cache and the next tool call reconnects. Every anticipated transport
// failure is a typed `throw[mcp.server_error]` (including a direct call's argument-lowering failure and a
// closed-scope rejection); a bare `error` completion is an engine-invariant panic.

import { randomBytes } from "node:crypto";
import type { Json } from "@katari-lang/types";
import { CALL_ERROR, dispatchCallable } from "../engine/dynamic-dispatch.js";
import { jsonValueFromJson, jsonValueToJson, type StringReader } from "../engine/json-value.js";
import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import {
  descriptorKeyOf,
  type McpToolListing,
  type McpTransport,
} from "../external/mcp-transport.js";
import { type DelegationId, newDelegationId, type SnapshotId } from "../ids.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import { jsonToSchema } from "../value/schema-json.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalCompletion,
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
const MCP_PROVIDE_KEY = "prelude.mcp.provide";
const MCP_SERVE_KEY = "prelude.mcp.serve";
const MCP_CALL_KEY = "prelude.mcp.call";

/** A transport-backed mcp call — the built-in client's OUTBOUND tool calls, told apart from a `provide` /
 *  `serve` endpoint at the TOP level of `McpPayload` (see below). A `callTool` dispatch (the tool's name,
 *  the descriptor + scope from the minted tool's context, the caller's argument verbatim), a `directCall`
 *  (`{url, auth, tool, arguments}` all in the call's own argument), or `recovered` — a reloaded transport
 *  call, which by construction can never be re-dispatched (at-most-once; nothing dispatch-shaped is
 *  persisted for the transport shapes). The listing a `provide` performs is NOT here: it rides a side
 *  `listing` delegation, so its completion mints the toolbox instead of settling a call. */
type TransportCall =
  | {
      kind: "callTool";
      tool: string;
      /** The minted tool's server descriptor; `null` only for a malformed target (no minted tool lacks
       *  one), which the transport rejects as the typed descriptor error. */
      descriptor: Value | null;
      /** The provide scope this tool was minted under — checked live before dispatch, so a tool outliving
       *  its `provide` (the covariance hole) is rejected as a typed `server_error`. `null` for a tool with
       *  no scope in its context (a legacy / hand-built target), which skips the check. */
      scope: string | null;
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

/** What an mcp call holds, a three-way sum whose TOP level every lifecycle method (dispatch / recover /
 *  abort / onDropCall / persistCallRow / loadCallRows) dispatches once: a `provide` scope (its scope id +
 *  descriptor + the not-yet-dispatched continuation — persisted, so the scope survives a restart), a
 *  `serve` endpoint (token + served tools — persisted), or a `transport` call (its `TransportCall`
 *  sub-shape plus its optional ack decoder). */
type McpPayload =
  | {
      kind: "provide";
      /** The snapshot the minted tools / continuation dispatch against — persisted as the ext row's version
       *  pin (retention: a live scope keeps its snapshot undeletable). */
      snapshot: SnapshotId;
      /** The runtime scope identity minted at open — carried in every minted tool's context, checked live at
       *  each tool call, closed at drop. Persisted so a restart re-registers exactly it. */
      scope: string;
      /** The `{url, auth}` descriptor the scope connects and evicts under (privacy markers intact). */
      descriptor: Value;
      /** The continuation to run inside the scope — consumed (set to `null`) once dispatched, so a reload
       *  distinguishes a listing-phase interruption (re-list) from an active scope (resume). */
      continuation: Value | null;
    }
  | {
      kind: "serve";
      /** The snapshot the call was dispatched against — persisted as the ext row's version pin (retention:
       *  a live endpoint keeps its snapshot undeletable, so the served agents stay resolvable). */
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
       *  a `directCall` lifts the raw reply literally into a `json` tree; `callTool` / `recovered` omit it,
       *  so the base wire decoder runs. */
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

/** The subscriber's / continuation's reserved inner-call tokens; served tool calls use fresh `delivery:`
 *  tokens. A provide's continuation and a serve's subscriber both ARE the whole call, so both settle it. */
const SUBSCRIBER_CALL = "subscriber";
const CONTINUATION_CALL = "continuation";

export class McpReactor extends ExternalCallReactor<McpPayload> {
  readonly name: ReactorName = "mcp";

  /** The live serve endpoints: a URL token to the call serving it. Registered at dispatch / reload,
   *  released at drop — so an inbound MCP request resolves its call in O(1). */
  private readonly tokens = new Map<string, DelegationId>();
  /** The live provide scopes: a scope identity to the provide serving it (with the descriptor and its cache
   *  key). Registered at dispatch / reload, released at drop — a minted tool call checks its scope here. */
  private readonly scopes = new Map<
    string,
    { delegation: DelegationId; descriptor: Value; descriptorKey: string }
  >();
  /** How many live provide scopes share each descriptor cache key — so the descriptor's connection is only
   *  evicted when the LAST scope on it closes (two provides of the same server share one cached client). */
  private readonly liveDescriptors = new Map<string, number>();
  /** A provide's in-flight listing: the side `listing` delegation the transport lists under, to its provide
   *  call. The listing's completion mints the toolbox (and dispatches the continuation) rather than settling
   *  a call — so a provide's own delegation never carries a transport call. */
  private readonly listings = new Map<DelegationId, DelegationId>();
  /** The HTTP requests awaiting a served tool call's outcome, by inner-call token. In-memory only: a
   *  waiter that dies with the process simply never answers (the MCP caller retries); the delivery
   *  itself is durable. */
  private readonly waiters = new Map<string, (outcome: McpServeCallOutcome) => void>();
  private deliverySequence = 0;

  constructor(
    private readonly transport: McpTransport,
    /** The public base the minted serve URLs are formed under (`<baseUrl>/mcp/<token>`). */
    private readonly baseUrl: string,
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how a serve / provide call's
     *  post-commit work (the subscriber / continuation dispatch, a synthesised completion) re-enters the
     *  transactional loop. */
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

  // ─── the provide scope registry ────────────────────────────────────────────────────────────────

  /** Register a provide's scope as live: index it by its identity and refcount its descriptor's cache key.
   *  Called at a fresh dispatch and at every reload of a running provide, so a tool call finds its scope. */
  private openScope(scope: string, delegation: DelegationId, descriptor: Value): void {
    // A well-formed `{url, auth}` always keys; a malformed one (wire drift) cannot match any call, so a
    // unique fallback key keeps the scope registered (its callTool check is by scope identity anyway) and
    // makes its eviction a harmless no-op.
    let descriptorKey: string;
    try {
      descriptorKey = descriptorKeyOf(valueToJson(descriptor, "reveal"));
    } catch {
      descriptorKey = `unkeyable:${scope}`;
    }
    this.scopes.set(scope, { delegation, descriptor, descriptorKey });
    this.liveDescriptors.set(descriptorKey, (this.liveDescriptors.get(descriptorKey) ?? 0) + 1);
  }

  /** Close a provide's scope at its drop: drop the identity, decref the descriptor, and evict the cached
   *  client when the last scope on that descriptor closes (the scope owns the connection's lifetime).
   *  Idempotent — a scope already closed (or never opened, a cancelling reload) decrefs nothing. */
  private closeScope(scope: string): void {
    const entry = this.scopes.get(scope);
    if (entry === undefined) return;
    this.scopes.delete(scope);
    const remaining = (this.liveDescriptors.get(entry.descriptorKey) ?? 1) - 1;
    if (remaining > 0) {
      this.liveDescriptors.set(entry.descriptorKey, remaining);
      return;
    }
    this.liveDescriptors.delete(entry.descriptorKey);
    this.transport.evict(valueToJson(entry.descriptor, "reveal"));
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(target: ExternalTarget, argument: Value | null): McpPayload {
    if (target.key === MCP_PROVIDE_KEY) {
      const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
      return {
        kind: "provide",
        snapshot: target.snapshot,
        // 18 random bytes, base64url — the scope identity minted tools carry and callTool checks.
        scope: `mcpscope:${randomBytes(18).toString("base64url")}`,
        descriptor: descriptorOf(argument),
        continuation: fields.continuation ?? null,
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
    // A minted tool's server-declared name: a callTool. Its context is `{ descriptor, scope }` (a legacy /
    // hand-built target may carry the bare descriptor and no scope — then the scope check is skipped).
    const context = target.context ?? null;
    const contextFields = context !== null && context.kind === "record" ? context.fields : {};
    const scopeValue = contextFields.scope;
    return {
      kind: "transport",
      call: {
        kind: "callTool",
        tool: target.key,
        descriptor: contextFields.descriptor ?? context,
        scope: scopeValue !== undefined && scopeValue.kind === "string" ? scopeValue.value : null,
        argument,
      },
    };
  }

  protected dispatch(delegation: DelegationId, payload: McpPayload): void {
    if (payload.kind === "provide") {
      // Post-commit: register the scope, then list the server (a side `listing` delegation, so the
      // completion mints the toolbox rather than settling this call). A fresh provide without a
      // continuation is a malformed call that would otherwise register a scope and sit forever —
      // fail it like serve fails a missing subscriber.
      this.openScope(payload.scope, delegation, payload.descriptor);
      if (payload.continuation === null) {
        this.schedule(() =>
          this.complete({
            delegation,
            outcome: { kind: "error", message: "mcp.provide: the continuation is missing" },
          }),
        );
        return;
      }
      this.startListing(delegation, payload);
      return;
    }
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
      case "callTool": {
        if (call.scope !== null && !this.scopes.has(call.scope)) {
          // The provide scope that minted this tool has closed — the covariance backstop. Reject with a
          // typed `server_error` naming the closed scope's server, so a tool called after its `provide`
          // returned fails catchably (never silently, never a panic).
          const url = descriptorUrl(call.descriptor);
          this.schedule(() =>
            this.complete({
              delegation,
              outcome: {
                kind: "throw",
                error: valueToJson(
                  errorData(
                    SERVER_ERROR,
                    `mcp: this tool's provide scope for ${url} has closed; a tool cannot be called after its mcp.provide returns`,
                  ),
                  "reveal",
                ),
              },
            }),
          );
          return;
        }
        this.transport.dispatch({
          kind: "callTool",
          delegation,
          tool: call.tool,
          descriptor: call.descriptor === null ? null : valueToJson(call.descriptor, "reveal"),
          argument: call.argument === null ? null : valueToJson(call.argument, "reveal"),
        });
        return;
      }
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

  /** List the server for a provide (a side `listing` delegation): the transport lists under it, and the
   *  completion resolves through `complete`'s listing interception — minting the toolbox and dispatching
   *  the continuation — so the provide's own delegation never carries a transport call. */
  private startListing(
    delegation: DelegationId,
    payload: Extract<McpPayload, { kind: "provide" }>,
  ): void {
    const listing = newDelegationId();
    this.listings.set(listing, delegation);
    this.transport.dispatch({
      kind: "listTools",
      delegation: listing,
      descriptor: valueToJson(payload.descriptor, "reveal"),
    });
  }

  /** A transport completion. A listing completion (its delegation is a live `listing`) mints the provide's
   *  toolbox and dispatches its continuation — it never settles a call; every other completion is an
   *  ordinary call completion the base handles. This is the ONE place a listing is told from a call. */
  override complete(completion: ExternalCompletion): void {
    const provideDelegation = this.listings.get(completion.delegation);
    if (provideDelegation === undefined) {
      super.complete(completion);
      return;
    }
    this.listings.delete(completion.delegation);
    this.onListingSettled(provideDelegation, completion.outcome);
  }

  /** A provide's listing settled. A `result` hands the block its minted toolbox on a fresh turn; a
   *  `cancelled` was the abort of a cancelling provide (its own cancel path confirms); a `throw` / `error`
   *  is a listing failure the block never saw — settle the provide with it. */
  private onListingSettled(delegation: DelegationId, outcome: ExternalCompletion["outcome"]): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "provide") return; // the provide resolved meanwhile
    switch (outcome.kind) {
      case "result":
        this.schedule(() => this.startContinuation(delegation, outcome.value));
        return;
      case "cancelled":
        return;
      case "throw":
      case "error":
        this.schedule(() => this.complete({ delegation, outcome }));
        return;
    }
  }

  /** The one-time continuation dispatch (a reactor turn) once the listing landed: mint the toolbox from the
   *  listing, and delegate the continuation with `{ value: toolbox }`. Its settlement is the whole call's
   *  settlement (see `deliverInnerOutcome`). The continuation is then consumed (`null`), so a reload from
   *  here resumes it as durable core work instead of re-listing. */
  private startContinuation(delegation: DelegationId, listingJson: Json): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.kind !== "provide") return; // resolved / cancelled meanwhile
    const continuation = payload.continuation;
    if (continuation === null) return; // already dispatched (a duplicate listing) — nothing to do
    const toolbox = mintToolbox(
      jsonToValue(listingJson),
      payload.descriptor,
      payload.scope,
      payload.snapshot,
    );
    const argument: Value = { kind: "record", fields: { value: toolbox } };
    const dispatched = dispatchCallable(continuation, argument);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: { kind: "error", message: `mcp.provide: the continuation is ${dispatched.error}` },
      });
      return;
    }
    const opened = this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      CONTINUATION_CALL,
      dispatched.generics,
    );
    if (opened === null) return; // the provide is winding down — its own cancel path settles it
    // Consumed: from here the continuation is a durable inner delegation, so stop persisting it (a reload
    // resumes that delegation instead of re-listing). `openInnerDelegation` already marked the call dirty.
    payload.continuation = null;
  }

  /** Finish a `directCall`'s dispatch. It is scope-gated like a minted tool but carries no scope id, so it
   *  must belong to a LIVE provide of the same descriptor (a generated binding sits inside its provide);
   *  none means it was called outside any provide — a typed `server_error` naming the descriptor. Then read
   *  the tool name, lower the arguments tree to its literal Json document (the `json.stringify` walk, so a
   *  blob-backed string leaf materialises), and hand the transport the SAME `callTool` operation a minted
   *  tool's call produces. The argument-lowering failure is program-anticipatable (a malformed tree), so it
   *  completes as the typed `throw[mcp.server_error]` DIRECTLY here — the same channel every other transport
   *  failure uses. */
  private async dispatchDirectCall(
    delegation: DelegationId,
    call: Extract<TransportCall, { kind: "directCall" }>,
  ): Promise<void> {
    const descriptorJson = valueToJson(call.descriptor, "reveal");
    let descriptorKey: string | null = null;
    try {
      descriptorKey = descriptorKeyOf(descriptorJson);
    } catch {
      descriptorKey = null;
    }
    if (descriptorKey === null || !this.liveDescriptors.has(descriptorKey)) {
      const url = descriptorUrl(call.descriptor);
      this.schedule(() =>
        this.complete({
          delegation,
          outcome: {
            kind: "throw",
            error: valueToJson(
              errorData(
                SERVER_ERROR,
                `mcp.call: no live mcp.provide scope for ${url}; a static tool call must run inside its provide scope`,
              ),
              "reveal",
            ),
          },
        }),
      );
      return;
    }
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
      descriptor: descriptorJson,
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

  /** A settled inner delegation. A provide's continuation and a serve's subscriber each ARE the whole
   *  call — feed the outcome back as the transport completion on a fresh turn; a served tool call's outcome
   *  resolves its waiting HTTP request (a waiter lost to a restart just drops it — the MCP caller retries). */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    if (delivery.call === SUBSCRIBER_CALL || delivery.call === CONTINUATION_CALL) {
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
    // A reloaded serve endpoint re-registers its token; a reloaded provide re-registers its scope, and
    // either re-lists (its continuation is still stored — the block never started) or resumes (the
    // continuation was dispatched, so it is durable core work); a transport call reconciles at-most-once.
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") {
      this.tokens.set(payload.token, delegation);
      return;
    }
    if (payload !== undefined && payload.kind === "provide") {
      this.openScope(payload.scope, delegation, payload.descriptor);
      if (payload.continuation !== null) this.startListing(delegation, payload);
      return;
    }
    this.transport.recover(delegation);
  }

  protected abort(delegation: DelegationId): void {
    // A serve / provide call has no transport half of its own: deactivate the endpoint / abort any in-flight
    // listing and confirm the cancel on a fresh turn (the children — subscriber, continuation, in-flight
    // served calls — drain through the base's cancel cascade; the scope closes at drop).
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") {
      this.tokens.delete(payload.token);
      this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
      return;
    }
    if (payload !== undefined && payload.kind === "provide") {
      for (const [listing, provide] of this.listings) {
        if (provide === delegation) this.transport.abort(listing);
      }
      this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
      return;
    }
    this.transport.abort(delegation);
  }

  /** A serve / provide call resolved: release its token / close its scope (the drop hook covers every
   *  resolution path at once) and forget any dangling listing bridge. */
  protected override onDropCall(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    if (payload.kind === "serve") {
      this.tokens.delete(payload.token);
      return;
    }
    if (payload.kind === "provide") {
      this.closeScope(payload.scope);
      for (const [listing, provide] of [...this.listings]) {
        if (provide === delegation) this.listings.delete(listing);
      }
    }
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<McpPayload>): Promise<void> {
    // A transport call persists only its status (at-most-once; no inner delegations, so its bridges are
    // empty — the status-only `mcp_instances` row); a serve / provide call persists its whole endpoint
    // extension (`mcp_serve_instances` / `mcp_provide_instances`: the payload + its inner-delegation
    // bridges), so a restart re-registers it.
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
      provide:
        row.payload.kind === "provide"
          ? {
              snapshotId: row.payload.snapshot,
              scopeId: row.payload.scope,
              descriptor: row.payload.descriptor,
              continuation: row.payload.continuation,
              relays: row.relays,
              innerCalls: row.innerCalls,
            }
          : null,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<McpPayload>>> {
    return (await loader.mcp.instances()).map((row) => {
      // A row with a serve / provide extension reloads as that live endpoint (the subscriber / continuation
      // was dispatched at the original open — the provide only if its continuation is now null; never
      // re-dispatched), carrying its inner-delegation bridges. A transport row (neither extension) reloads
      // as `recovered`: nothing dispatch-shaped is persisted for it, so the payload says so by type.
      const endpoint = row.serve ?? row.provide;
      const payload: McpPayload =
        row.serve !== null
          ? {
              kind: "serve",
              token: row.serve.token,
              snapshot: row.serve.snapshotId,
              tools: row.serve.tools,
              subscriber: null,
            }
          : row.provide !== null
            ? {
                kind: "provide",
                snapshot: row.provide.snapshotId,
                scope: row.provide.scopeId,
                descriptor: row.provide.descriptor,
                continuation: row.provide.continuation,
              }
            : { kind: "transport", call: { kind: "recovered" } };
      return {
        delegation: row.delegation,
        instance: row.instance,
        caller: row.caller,
        run: row.run,
        status: row.status,
        payload,
        relays: endpoint?.relays ?? [],
        innerCalls: endpoint?.innerCalls ?? [],
      };
    });
  }

  override reset(): void {
    super.reset();
    this.tokens.clear();
    this.scopes.clear();
    this.liveDescriptors.clear();
    this.listings.clear();
    // Waiters are in-process HTTP requests; a reset (poisoned commit) makes their calls unresolvable.
    for (const waiter of this.waiters.values()) waiter({ kind: "gone" });
    this.waiters.clear();
  }
}

/** The domain error ctor every anticipated mcp transport failure throws (`prelude/mcp.ktr` declares it). */
const SERVER_ERROR = "prelude.mcp.server_error";

/** The `{url, auth}` descriptor of a `provide` / `directCall`, from its original (marker-bearing) argument. */
function descriptorOf(argument: Value | null): Value {
  if (argument === null || argument.kind !== "record") {
    return { kind: "record", fields: {} };
  }
  const fields: Record<string, Value> = Object.create(null);
  if (argument.fields.url !== undefined) fields.url = argument.fields.url;
  if (argument.fields.auth !== undefined) fields.auth = argument.fields.auth;
  return { kind: "record", fields };
}

/** The server url a descriptor names, for a scope-rejection message (a `<server>` placeholder when the
 *  descriptor carries no string url — wire drift, which would fail at the transport regardless). */
function descriptorUrl(descriptor: Value | null): string {
  if (descriptor !== null && descriptor.kind === "record") {
    const url = descriptor.fields.url;
    if (url !== undefined && url.kind === "string") return url.value;
  }
  return "<server>";
}

/** Mint the toolbox for a settled `provide` listing: one agent value per server tool, carrying the
 *  server-declared signature and — as its context — a record of the DESCRIPTOR (`{url, auth}` with privacy
 *  markers intact; the transport's revealed copy is never minted) and this provide's SCOPE identity, which
 *  each tool call checks live. */
function mintToolbox(
  listing: Value,
  descriptor: Value,
  scope: string,
  snapshot: SnapshotId,
): Value {
  const context: Value = {
    kind: "record",
    fields: { descriptor, scope: { kind: "string", value: scope } },
  };
  const fields: Record<string, Value> = Object.create(null);
  for (const tool of listingsOf(listing)) {
    fields[tool.name] = {
      kind: "tool",
      reactor: "mcp",
      name: tool.name,
      description: tool.description,
      context,
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
