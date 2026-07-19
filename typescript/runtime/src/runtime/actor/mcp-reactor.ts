// McpReactor: the `mcp` reactor — the built-in MCP client AND inbound MCP server as a call reactor (see
// `ExternalCallReactor` for the shared callee-call lifecycle). Four call shapes reach it, told apart ONCE
// at the `openPayload` boundary (the compiled `prelude.mcp.provide` / `prelude.mcp.serve` /
// `prelude.mcp.call` externals arrive as their qualified names on the wire; every other key is a minted
// tool's server-declared name):
//   - `provide` (the `prelude.mcp.provide` external): a SCOPED provider (the `runST` shape). It lists the
//     server ONCE (an internal transport `listTools`, keyed by a side `listing` delegation so its completion
//     never settles the provide call), MINTS one agent value per tool — a `$katari_tool` carrying the server
//     signature and, as its context, the server DESCRIPTOR plus this provide's runtime SCOPE identity — and
//     dispatches the CONTINUATION as an inner delegation receiving `{ value: toolbox }`. The whole call
//     settles with the continuation's outcome (the serve/webhook `innerOutcomeAsCompletion` template). While
//     the provide is live the scope is registered; a tool call carrying it proceeds on the same transport
//     path a listing-minted tool always did; when the provide settles or cancels the scope closes — the
//     descriptor's cached client is evicted and any later call carrying that scope is rejected as a typed
//     `server_error` (the requires-a-live-provide boundary — the scope's identity is a compiler-only marker,
//     so the runtime never inspects it; it routes and gates purely by the tool's own descriptor).
//   - `callTool` (a minted tool's call, an `external` target carrying `{ descriptor, scope }` as `context`):
//     the caller's argument passes to the transport verbatim; the descriptor rides out-of-band; the scope is
//     checked live first (a closed scope is the typed `server_error` backstop).
//   - `directCall` (the `prelude.mcp.call` external): the STATIC counterpart of a minted tool's call —
//     a compiled external carries no context, so everything (`{url, auth, tool, arguments}`) rides in
//     the call's own argument, and the call's own instantiation (`mcp.call[url, T]`) rides as the delegate's
//     `generics`. It is scope-gated too, but carries no scope id: it must belong to a LIVE provide of the
//     same descriptor (a generated binding sits inside `with_tools`'s provide), else the typed `server_error`
//     names the missing provide. `arguments` is now a plain value tree (`unknown`); it lowers to the literal
//     Json document at dispatch through the SAME `http.json` slot contract — `valueToJson` then the http-body
//     materialiser — so keys travel verbatim, a `file` leaf base64s in place, and a blob-backed string
//     materialises. The transport's reply is DECODED UNCONDITIONALLY (`decodeDirectReply`): the wire's own
//     `$katari_*` markers drive reconstruction REGARDLESS of `T` — a produced blob's `$katari_ref` becomes a
//     REAL `file` (whose lifetime the ownership hoist on the ack, and the ordinary reown walk, then bound), a
//     `$katari_constructor` object a data value, a plain-text reply the string value a string-shaped `T`
//     wants. `T` only VALIDATES: a constrained `T` conforms the decoded value (a mismatch — or a marker the
//     wire cannot reconstruct — is the typed `json.validation_error` throw the row declares), while
//     `T = unknown` (the codegen's no-`outputSchema` choice) accepts the decode as-is.
//   - `serve` (the `prelude.mcp.serve` external): the INBOUND direction, mirroring the webhook reactor —
//     no transport at all. It mints an unguessable token (the public URL's capability), dispatches the
//     SUBSCRIBER once as an inner delegation carrying that URL, and converts every MCP `tools/call` to
//     that URL into an inner delegation of the named agent in the served tools record (resolved through
//     the shared `dispatchCallable`, so the callee validates — a mismatch surfaces as
//     `reflection.call_error` without ever failing the run). The call settles when the SUBSCRIBER
//     settles; a `terminate` from above cancels it and releases the token either way.
//
// A payload is a three-way sum — `provide | serve | transport{callTool|directCall|recovered}` — so every
// lifecycle method dispatches that axis once, structurally. Durably the same sum is the `McpExtension`
// document (`transport | serve | provide | parked`, one tag — see the codec below): `provide` and `serve`
// persist their endpoint payloads in their variants (a provide's scope id + descriptor + still-listing
// continuation + inner-delegation bridges; a serve's token + tools + bridges) and survive a restart
// COMPLETELY (re-registering the scope / token, the inner delegation resuming as durable core work). The
// transport-backed shapes persist the bare `transport` tag (no argument is persisted) and recovery never
// re-runs, so a reloaded transport call's payload is the explicit `recovered` variant — nothing
// dispatch-shaped survives a restart by type. Connections are the TRANSPORT's business (a lazy,
// descriptor-keyed cache), not a program-visible resource: a restart empties the cache and the next tool
// call reconnects. Every anticipated transport failure is a typed `throw[mcp.server_error]` (including a
// direct call's argument-lowering failure and a closed-scope rejection); a bare `error` completion is an
// engine-invariant panic.
//
// OAuth authorization is the one failure that is NEITHER: an `authorizationRequired` completion (an
// `oauth`-descriptor operation that could not authenticate — see the transport's classification) PARKS the
// operation instead of settling it, through the BASE reactor's shared credential-park machinery (a general
// "a call parks pending a credential, and re-runs its dispatch on the answering ack" concern). The reactor
// supplies only its two profile-specific bits: the TRIGGER (`complete`'s `authorizationRequired` branch
// calls `parkCall`, which raises the base `prelude.oauth.authorize` escalation from the call's own instance)
// and the RE-DISPATCH (`redispatchParked` re-lists a provide, or re-runs a tool / direct call, from
// scratch). The answering `escalateAck` — its value deliberately ignored — makes the base re-run the parked
// operation: the transport reconnects and re-reads the credential store. Still-unusable material parks again
// with a fresh escalation; first authorization, refresh death, an empty answer, and every race collapse into
// this ONE loop. Re-running is at-most-once-safe because the parked attempt was REJECTED (an HTTP 401
// rejection guarantees the server never executed it) — which is also why the park may persist dispatch-shaped
// state no in-flight transport call ever does: a parked call's re-runnable dispatch rides the extension's
// `parked` variant (written with the escalation row, reverted to `transport` with its answer, in the same
// commits), so a reload reconstructs the FULL park — a provide re-lists from its extension, a transport
// call re-dispatches its stored call — and a post-reload ack retries identically to a warm one. A
// reloaded call with NO open authorize escalation stays the at-most-once `recovered` refusal, exactly as
// before: parked versus in-flight is a true sum, discriminated by the escalation row's presence.

import { randomBytes } from "node:crypto";
import type { JSONSchema, Json, QualifiedName } from "@katari-lang/types";
import { CALL_ERROR, dispatchCallable } from "../engine/dynamic-dispatch.js";
import type { StringReader } from "../engine/json-value.js";
import { errorData } from "../engine/throw-signal.js";
import type { ReactorName } from "../event/types.js";
import { OAUTH_AUTHORIZE_REQUEST } from "../external/credentials.js";
import { type HttpBlobResolver, materializeJsonTree } from "../external/http-body.js";
import {
  descriptorKeyOf,
  type McpCompletion,
  type McpToolListing,
  type McpTransport,
} from "../external/mcp-transport.js";
import { type DelegationId, type InstanceId, newDelegationId, type SnapshotId } from "../ids.js";
import type { McpDispatchCall } from "../mcp-dispatch.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import { jsonToSchema } from "../value/schema-json.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { conformValue, isUnconstrained, renderConformFailures } from "../value/validation.js";
import {
  asJson,
  documentOf,
  encodeInnerCalls,
  encodeRelays,
  innerCallsOf,
  relaysOf,
  stringFieldOf,
  warmFieldOf,
} from "./extension-codec.js";
import {
  type CallRow,
  type DecodedCallExtension,
  type EscalationRelayRow,
  ExternalCallReactor,
  type ExternalCompletion,
  type ExternalTarget,
  type InnerCallRow,
  type InnerDelivery,
  innerOutcomeAsCompletion,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { ResourcePool } from "./resource-pool.js";

/** The reserved dispatch keys the compiled `prelude.mcp.*` externals arrive under — compared exactly
 *  here, at the payload boundary (tool names are server-scoped and never dotted like this, so they
 *  cannot collide). Past `openPayload` the call shapes are distinct payload variants, not key sniffs. */
const MCP_PROVIDE_KEY = "prelude.mcp.provide";
const MCP_SERVE_KEY = "prelude.mcp.serve";
const MCP_CALL_KEY = "prelude.mcp.call";

/** A transport-backed mcp call — the built-in client's OUTBOUND tool calls, told apart from a `provide` /
 *  `serve` endpoint at the TOP level of `McpPayload` (see below). The dispatch-shaped half (`callTool` /
 *  `directCall`) is the shared durable `McpDispatchCall` (see `mcp-dispatch.ts` — it persists as the
 *  extension's `parked` variant while the call is parked on an authorize escalation, which is what lets a
 *  reloaded park re-run); `recovered` is a reloaded NON-parked transport call, which by construction can
 *  never be re-dispatched (at-most-once; an interrupted in-flight call may have executed server-side, and
 *  nothing dispatch-shaped persists for it). The listing a `provide` performs is NOT here: it rides a side
 *  `listing` delegation, so its completion mints the toolbox instead of settling a call. */
type TransportCall = McpDispatchCall | { kind: "recovered" };

/** What an mcp call holds, a three-way sum whose TOP level every lifecycle method (dispatch / recover /
 *  abort / onDropCall / the extension codec hooks) dispatches once: a `provide` scope (its scope id +
 *  descriptor + the not-yet-dispatched continuation — persisted, so the scope survives a restart), a
 *  `serve` endpoint (token + served tools — persisted), or a `transport` call (its `TransportCall`
 *  sub-shape plus its optional ack decoder). */
type McpPayload =
  | {
      kind: "provide";
      /** The snapshot the minted tools / continuation dispatch against — persisted in the extension
       *  document, so a reloaded scope dispatches against the same version. */
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
      /** The snapshot the call was dispatched against — persisted in the extension document, so a
       *  reloaded endpoint dispatches its served agents against the same version. */
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
       *  a `directCall` decodes the raw reply against its `T` (literal document for `unknown`, wire form for
       *  a typed `T`); `callTool` / `recovered` omit it, so the base wire decoder runs. */
      decodeAck?: (raw: Json) => Value;
    };

/** An mcp call's durable extension document — a REAL sum, one tag: a bare `transport` call persists
 *  nothing beyond the tag (at-most-once, no argument at rest), a `serve` / `provide` endpoint persists
 *  the payload a restart re-registers (with its inner-delegation bridges — only the endpoint shapes open
 *  inner delegations), and a `parked` transport call persists its re-runnable dispatch (its rejected
 *  attempt provably never executed server-side, so a reloaded park may re-run it — written in the same
 *  commit that opens the authorize escalation, reverted to `transport` in the one that answers it, so
 *  "open authorize row" ⟺ "parked variant"). A parked PROVIDE stays the `provide` variant: its
 *  still-stored continuation already says "re-list", and the open escalation row alone marks the park. */
export type McpExtension =
  | { kind: "transport" }
  | { kind: "parked"; call: McpDispatchCall }
  | {
      kind: "serve";
      snapshotId: SnapshotId;
      token: string;
      tools: Value;
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    }
  | {
      kind: "provide";
      snapshotId: SnapshotId;
      scopeId: string;
      descriptor: Value;
      continuation: Value | null;
      relays: EscalationRelayRow[];
      innerCalls: InnerCallRow[];
    };

/** Encode an mcp call's extension document (pure — the persistence port seals it as a whole; the
 *  descriptor / tools / continuation / parked call may carry private leaves, and they seal in place). */
export function encodeMcpExtension(extension: McpExtension): Json {
  switch (extension.kind) {
    case "transport":
      return { kind: "transport" };
    case "parked":
      return { kind: "parked", call: asJson(extension.call) };
    case "serve":
      return {
        kind: "serve",
        snapshotId: extension.snapshotId,
        token: extension.token,
        tools: asJson(extension.tools),
        relays: encodeRelays(extension.relays),
        innerCalls: encodeInnerCalls(extension.innerCalls),
      };
    case "provide":
      return {
        kind: "provide",
        snapshotId: extension.snapshotId,
        scopeId: extension.scopeId,
        descriptor: asJson(extension.descriptor),
        continuation: asJson(extension.continuation),
        relays: encodeRelays(extension.relays),
        innerCalls: encodeInnerCalls(extension.innerCalls),
      };
  }
}

/** Decode an mcp call's extension document (pure) — one tag dispatch, no "at most one non-null" prose. */
export function decodeMcpExtension(extension: Json): McpExtension {
  const document = documentOf(extension);
  const kind = stringFieldOf(document, "kind");
  switch (kind) {
    case "transport":
      return { kind: "transport" };
    case "parked":
      return { kind: "parked", call: warmFieldOf<McpDispatchCall>(document, "call") };
    case "serve":
      return {
        kind: "serve",
        snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
        token: stringFieldOf(document, "token"),
        tools: warmFieldOf<Value>(document, "tools"),
        relays: relaysOf(document),
        innerCalls: innerCallsOf(document),
      };
    case "provide":
      return {
        kind: "provide",
        snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
        scopeId: stringFieldOf(document, "scopeId"),
        descriptor: warmFieldOf<Value>(document, "descriptor"),
        continuation: warmFieldOf<Value | null>(document, "continuation"),
        relays: relaysOf(document),
        innerCalls: innerCallsOf(document),
      };
    default:
      throw new Error(`unknown mcp extension kind "${kind}" (corrupt row)`);
  }
}

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
     *  `directCall`'s tool-name lowering needs at dispatch. */
    private readonly readString: StringReader,
    /** Reads a blob's bytes + content type — what a `directCall`'s argument tree needs at dispatch to
     *  base64 a `file` leaf in place (the same slot contract as an `http.json` body). */
    private readonly resolveBlob: HttpBlobResolver,
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

  protected openPayload(
    target: ExternalTarget,
    argument: Value | null,
    generics: GenericSubstitution | undefined,
  ): McpPayload {
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
      return transportPayloadOf({
        kind: "directCall",
        descriptor: descriptorOf(argument),
        tool: fields.tool ?? null,
        argumentsTree: fields.arguments ?? null,
        outputSchema: directCallOutputSchema(generics),
      });
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
    return transportPayloadOf({
      kind: "callTool",
      tool: target.key,
      descriptor: contextFields.descriptor ?? context,
      scope: scopeValue !== undefined && scopeValue.kind === "string" ? scopeValue.value : null,
      argument,
    });
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
      case "callTool":
        this.dispatchToolCall(delegation, call);
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

  /** Ship one minted tool's call to the transport (a fresh dispatch, or an authorize retry re-running the
   *  parked call). The scope gate re-checks on every attempt: a retry whose provide closed while it was
   *  parked must reject exactly like a fresh call of an escaped tool. */
  private dispatchToolCall(
    delegation: DelegationId,
    call: Extract<TransportCall, { kind: "callTool" }>,
  ): void {
    if (call.scope !== null && !this.scopes.has(call.scope)) {
      // The provide scope that minted this tool has closed — the requires-a-live-provide boundary. Reject
      // with a typed `server_error` naming the closed scope's server, so a tool called after its `provide`
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

  /** The park request the mcp reactor raises and reconstructs from — turning on the base's credential-park
   *  machinery (`parkCall` / `reconstructPark` / `isParked` / `redispatchParked`). */
  protected override parkRequestName(): QualifiedName {
    return OAUTH_AUTHORIZE_REQUEST;
  }

  /** A transport completion. An `authorizationRequired` outcome settles nothing — it parks the operation
   *  (a listing's park belongs to its provide; every other operation parks its own call), raising the base
   *  authorize escalation with the descriptor's `{ url, name }`. A listing completion (its delegation is a
   *  live `listing`) mints the provide's toolbox and dispatches its continuation — it never settles a call;
   *  every other completion is an ordinary call completion the base handles. This is the ONE place a
   *  listing is told from a call. */
  override complete(completion: McpCompletion): void {
    const outcome = completion.outcome;
    const provideDelegation = this.listings.get(completion.delegation);
    if (outcome.kind === "authorizationRequired") {
      if (provideDelegation !== undefined) this.listings.delete(completion.delegation);
      this.parkCall(
        provideDelegation ?? completion.delegation,
        authorizeArgument(outcome.url, outcome.name),
      );
      return;
    }
    if (provideDelegation === undefined) {
      super.complete(this.directCallCompletion({ delegation: completion.delegation, outcome }));
      return;
    }
    this.listings.delete(completion.delegation);
    this.onListingSettled(provideDelegation, outcome);
  }

  /** A direct call's transport completion, with a reply that does not conform to its `T` re-shaped into
   *  the typed `json.validation_error` throw the `call` row declares. The `decodeAck` seam that BUILDS the
   *  reply value cannot itself throw (it runs at the settle / resource-ascent boundary), so the mismatch
   *  is decided here — before the base settles — and turned into a throw completion. A callTool /
   *  recovered completion has no `T` to decode, and a non-`result` outcome (a throw / cancel) is already
   *  its own channel, so both pass through untouched. */
  private directCallCompletion(completion: ExternalCompletion): ExternalCompletion {
    if (completion.outcome.kind !== "result") return completion;
    const payload = this.payloadOf(completion.delegation);
    if (
      payload === undefined ||
      payload.kind !== "transport" ||
      payload.call.kind !== "directCall"
    ) {
      return completion;
    }
    const { mismatch } = decodeDirectReply(completion.outcome.value, payload.call.outputSchema);
    if (mismatch === null) return completion;
    return {
      delegation: completion.delegation,
      outcome: {
        kind: "throw",
        error: validationError(`mcp.call: the reply does not conform to T — ${mismatch}`),
      },
    };
  }

  /** An undecodable tool reply — a hostile MCP server whose `structuredContent` mimics a `$katari_*` marker
   *  the wire cannot reconstruct — is a program-anticipatable transport failure like every other: fold it
   *  into `throw[mcp.server_error]` so the settle seam stays total (a hostile server cannot poison the
   *  actor). This fires only for a `callTool`: a `directCall`'s undecodable reply is already re-shaped into a
   *  `validation_error` throw in `directCallCompletion`, BEFORE the seam, and a `listing` never settles a
   *  call. */
  protected override escalateResultDecodeFailure(
    delegation: DelegationId,
    cause: unknown,
    caller: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.raiseThrow(
      delegation,
      errorData(SERVER_ERROR, `mcp: the tool reply could not be decoded — ${messageOf(cause)}`),
      caller,
      run,
      raiser,
    );
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
    const toolbox = mintToolbox(listingJson, payload.descriptor, payload.scope, payload.snapshot);
    // `{ value: toolbox }` conforms to the continuation's declared input BY CONSTRUCTION: `mcp.provide`'s
    // signature types the continuation as `agent (value: toolbox[URL]) -> ...`, and `mintToolbox` produces
    // exactly a `toolbox[URL]` (a record of the minted tools) for this same provide's URL. So this internal
    // dispatch — which does not go through a dynamic-input boundary's pre-check — never mismatches at the
    // acceptance surface, and needs no guard of its own (a `dispatchCallable` error is a non-callable
    // continuation, still handled below).
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
      // Lower the argument value tree to its literal JSON document: `valueToJson` renders the wire form
      // (a `file` becoming a `$katari_ref` handle), which the http-body materialiser then turns into the
      // SEND-boundary document — a `file` leaf base64 in place, a blob-backed string materialised, keys
      // verbatim. The one shared slot contract with `http.json`.
      argumentDocument =
        call.argumentsTree === null
          ? null
          : await materializeJsonTree(valueToJson(call.argumentsTree, "reveal"), this.resolveBlob);
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
      case "error":
        waiter({ kind: "error", message: delivery.outcome.message });
        return;
      case "cancelled":
        waiter({ kind: "gone" });
        return;
    }
  }

  /** Re-run one parked operation after its authorize escalation was answered — the base calls this
   *  post-commit and only while the call is still `running`. The re-run starts FROM SCRATCH — reconnect,
   *  re-read the credential store — and a still-failing attempt parks again with a fresh escalation: the
   *  one unbounded authorize loop (the base owns the loop; this only re-dispatches mcp's own operation). */
  protected override redispatchParked(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return; // the call resolved while the retry was staged (a racing cancel)
    switch (payload.kind) {
      case "provide":
        // Parked at the listing, so the toolbox was never minted and the continuation is still stored:
        // list again from scratch.
        this.startListing(delegation, payload);
        return;
      case "serve":
        return; // unreachable: a serve has no transport operation and never parks
      case "transport": {
        const call = payload.call;
        switch (call.kind) {
          case "callTool":
            this.dispatchToolCall(delegation, call);
            return;
          case "directCall":
            void this.dispatchDirectCall(delegation, call);
            return;
          case "recovered":
            // Unreachable by construction: a park's escalation row and its extension's `parked` variant
            // are written and reverted in the same commits, so a call the parked set names always holds its
            // re-runnable dispatch (a reloaded park carries it; a non-parked reload is never in the set).
            throw new Error(`mcp: parked call ${delegation} reloaded without its dispatch (bug)`);
        }
      }
    }
  }

  protected recover(delegation: DelegationId): void {
    // A reloaded serve endpoint re-registers its token; a reloaded provide re-registers its scope, and
    // either re-lists (its continuation is still stored — the block never started) or resumes (the
    // continuation was dispatched, so it is durable core work); a transport call reconciles at-most-once.
    // For BOTH provide and transport shapes, an open raised authorize escalation overrides that default:
    // the row IS the durable park state, so the call reconstructs as parked — waiting for the ack, never
    // refused by the reconciliation (its rejected attempt provably never executed server-side).
    const payload = this.payloadOf(delegation);
    if (payload !== undefined && payload.kind === "serve") {
      this.tokens.set(payload.token, delegation);
      return;
    }
    if (payload !== undefined && payload.kind === "provide") {
      this.openScope(payload.scope, delegation, payload.descriptor);
      if (this.reconstructPark(delegation)) return;
      if (payload.continuation !== null) this.startListing(delegation, payload);
      return;
    }
    if (this.reconstructPark(delegation)) return;
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

  /** A call resolved: release a serve's token / close a provide's scope (the drop hook covers every
   *  resolution path at once), and forget any dangling listing bridge. The park index is the base's to
   *  evict (a parked call resolves only by teardown — the durable escalation row cascades with the raiser). */
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

  /** Pick the durable extension variant for one call. A transport call persists only the `transport` tag
   *  (at-most-once; no inner delegations, so no bridges) — EXCEPT while parked on an authorize escalation,
   *  when its re-runnable dispatch persists as `parked` (the rejected attempt provably never executed, so
   *  a reloaded park may re-run it; `isParked` is the base's park state, which is why this is a hook and
   *  the codec stays pure). A serve / provide call persists its whole endpoint variant (payload +
   *  bridges), so a restart re-registers it. */
  protected encodeCallExtension(row: CallRow<McpPayload>): Json {
    const payload = row.payload;
    switch (payload.kind) {
      case "serve":
        return encodeMcpExtension({
          kind: "serve",
          snapshotId: payload.snapshot,
          token: payload.token,
          tools: payload.tools,
          relays: row.relays,
          innerCalls: row.innerCalls,
        });
      case "provide":
        return encodeMcpExtension({
          kind: "provide",
          snapshotId: payload.snapshot,
          scopeId: payload.scope,
          descriptor: payload.descriptor,
          continuation: payload.continuation,
          relays: row.relays,
          innerCalls: row.innerCalls,
        });
      case "transport":
        return encodeMcpExtension(
          payload.call.kind !== "recovered" && this.isParked(row.delegation)
            ? { kind: "parked", call: payload.call }
            : { kind: "transport" },
        );
    }
  }

  /** Reload one call from its extension variant. A `serve` / `provide` reloads as that live endpoint (the
   *  subscriber / continuation was dispatched at the original open — the provide re-lists only if its
   *  continuation is still stored; never re-dispatched), carrying its inner-delegation bridges. A `parked`
   *  variant reloads as its full dispatch-shaped call (the park's re-run needs it — the ack decoder is
   *  rebuilt exactly as `openPayload` built it); a bare `transport` reloads as `recovered`: nothing
   *  dispatch-shaped persists for an in-flight call, so the payload says so by type. */
  protected decodeCallExtension(extension: Json): DecodedCallExtension<McpPayload> {
    const decoded = decodeMcpExtension(extension);
    switch (decoded.kind) {
      case "serve":
        return {
          payload: {
            kind: "serve",
            token: decoded.token,
            snapshot: decoded.snapshotId,
            tools: decoded.tools,
            subscriber: null,
          },
          relays: decoded.relays,
          innerCalls: decoded.innerCalls,
        };
      case "provide":
        return {
          payload: {
            kind: "provide",
            snapshot: decoded.snapshotId,
            scope: decoded.scopeId,
            descriptor: decoded.descriptor,
            continuation: decoded.continuation,
          },
          relays: decoded.relays,
          innerCalls: decoded.innerCalls,
        };
      case "parked":
        return { payload: transportPayloadOf(decoded.call), relays: [], innerCalls: [] };
      case "transport":
        return {
          payload: { kind: "transport", call: { kind: "recovered" } },
          relays: [],
          innerCalls: [],
        };
    }
  }

  /** A serve endpoint's minted URL token — the base commits its `capability_routes` row alongside the
   *  call row, so a cold `POST /mcp/<token>` resolves this project before any actor is warm. The other
   *  shapes mint no public token. */
  protected override capabilityTokenOf(payload: McpPayload): string | null {
    return payload.kind === "serve" ? payload.token : null;
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

/** The domain error ctor a reply that does not conform to `T` throws — `prelude.json.validation_error` (the
 *  same "value does not fit T" error `json.validate` raises), which `prelude/mcp.ktr`'s `call` row carries so
 *  a wrapper propagates it. */
const VALIDATION_ERROR = "prelude.json.validation_error";

/** The wire form of a `prelude.json.validation_error` throw (decoded back into the data value at the reactor
 *  base's throw path), matching the transport's `server_error` / `auth_error` shaping. */
function validationError(message: string): Json {
  return valueToJson(errorData(VALIDATION_ERROR, message), "reveal");
}

/** The result generic `T`'s schema, from a direct call's own instantiation (`mcp.call[url, T]` — `T` is
 *  the result generic, so its argument is a type schema). Absent — an un-instantiated call, or IR from a
 *  compiler predating instantiation stamping — keeps the reply as the raw document value. */
function directCallOutputSchema(generics: GenericSubstitution | undefined): JSONSchema | undefined {
  const bound = generics?.T;
  return bound !== undefined && bound.kind === "type" ? bound.schema : undefined;
}

/** The transport payload one dispatch-shaped call rides as — shared by a fresh `openPayload` and a parked
 *  call's reload, so the ack-decoding seam cannot drift between the two. A `directCall` decodes its raw
 *  transport reply UNCONDITIONALLY (see `decodeDirectReply`): the wire's own `$katari_*` markers drive
 *  reconstruction — a `$katari_ref` becomes a REAL `file`, a `$katari_constructor` a data value — never the
 *  declared `T`, which only VALIDATES the result. The seam only BUILDS the value; a reply that does not
 *  conform (or carries a marker the wire cannot reconstruct) is re-shaped into the typed `validation_error`
 *  throw in `complete`, so it never throws here. A `callTool` carries no `T` and runs the base wire decoder. */
function transportPayloadOf(call: McpDispatchCall): Extract<McpPayload, { kind: "transport" }> {
  if (call.kind === "callTool") {
    return { kind: "transport", call };
  }
  const outputSchema = call.outputSchema;
  return {
    kind: "transport",
    call,
    decodeAck: (raw) => decodeDirectReply(raw, outputSchema).value,
  };
}

/** Decode a direct call's transport reply. The wire-to-value conversion is UNCONDITIONAL — never
 *  schema-directed: the reply is always read through the value codec, so the wire's own `$katari_*` markers
 *  drive reconstruction (a `$katari_ref` becomes a REAL `file`, a `$katari_constructor` object a data value,
 *  records / arrays / scalars ordinary values, a plain-text reply the string value a string-shaped `T` wants).
 *  This is the same principle `json`'s codec obeys: interpretation is the wire's business, validation a
 *  separate pass — the declared `T` never changes what a value MEANS, only whether it is accepted. `T` is thus
 *  a pure VALIDATION gate: an UNCONSTRAINED `T` (`unknown` — the codegen's no-`outputSchema` choice) accepts
 *  the decode as-is; a constrained `T` conforms it. `mismatch` names the offending path when the value does
 *  not conform — or when a marker cannot be reconstructed at all (a `$katari_ref` whose id is not a string, a
 *  withheld `$katari_redacted` marker), which is a validation failure at ANY `T`, `unknown` included. The
 *  caller turns a non-`null` `mismatch` into the typed `validation_error` throw, since the settle-time seam
 *  that reads `value` cannot itself throw. */
function decodeDirectReply(
  raw: Json,
  schema: JSONSchema | undefined,
): { value: Value; mismatch: string | null } {
  let wire: Value;
  try {
    wire = jsonToValue(raw);
  } catch (cause) {
    // A marker the wire cannot reconstruct (a `$katari_ref` whose id is not a string, a `$katari_redacted`
    // marker) IS the validation_error — at any `T`, since the decode is unconditional. The value slot is
    // never delivered (the caller throws on a non-null mismatch), so an empty record keeps the seam total.
    return { value: { kind: "record", fields: {} }, mismatch: messageOf(cause) };
  }
  if (schema === undefined || isUnconstrained(schema)) {
    return { value: wire, mismatch: null };
  }
  const result = conformValue(wire, schema);
  return { value: wire, mismatch: result.ok ? null : renderConformFailures(result.failures) };
}

/** The `{ url, name }` record a `prelude.oauth.authorize` escalation carries — the server url and the
 *  credential name, stamped from the descriptor at the transport's classification boundary. Identity
 *  only, never token material: the argument rides the plaintext audit and the admin wire, and the
 *  answer's value is ignored (the credential travels through the store, not the escalation). */
function authorizeArgument(url: string, name: string): Value {
  return {
    kind: "record",
    fields: {
      url: { kind: "string", value: url },
      name: { kind: "string", value: name },
    },
  };
}

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
function mintToolbox(listing: Json, descriptor: Value, scope: string, snapshot: SnapshotId): Value {
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

/** The transport's `{ tools: [...] }` listing, read straight from the completion's bare Json — the server
 *  schemas ride to `jsonToSchema` LITERALLY (a JSON-Schema keyword like `$defs` is part of the schema, not a
 *  value to route through the value codec). A malformed shape is transport drift, not a program error — fail
 *  loudly (the substrate surfaces it). */
function listingsOf(listing: Json): McpToolListing[] {
  if (listing === null || typeof listing !== "object" || Array.isArray(listing)) {
    throw new Error("mcp: the tools completion did not carry a { tools: [...] } listing");
  }
  const tools = listing.tools;
  if (!Array.isArray(tools)) {
    throw new Error("mcp: the tools completion did not carry a { tools: [...] } listing");
  }
  const listings: McpToolListing[] = [];
  for (const entry of tools) {
    if (entry === null || typeof entry !== "object" || Array.isArray(entry)) continue;
    const name = entry.name;
    if (typeof name !== "string") continue;
    listings.push({
      name,
      description: typeof entry.description === "string" ? entry.description : "",
      inputSchema: entry.inputSchema ?? {},
      ...(entry.outputSchema !== undefined ? { outputSchema: entry.outputSchema } : {}),
    });
  }
  return listings;
}
