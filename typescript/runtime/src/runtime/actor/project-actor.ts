// ProjectActor: the warm, per-project composition root. It wires three siblings together: the `Substrate`
// (the transactional bus — serial mailbox + the one atomic commit per turn, routing by `to`), the
// `CoreReactor` (the engine — instances, the delegation graph, the IR turns), and the `ApiReactor` (the
// user-facing management root — runs and escalations). It owns no engine state itself; it supplies the
// substrate's reactor registry and the domain half of reactivation, and bridges the out-of-loop entry points
// (in-process api commands, FFI completions) onto the serial bus. Everything is serial; concurrency is the
// ack model (a parent that fanned out several delegates resumes each branch as its delegateAck lands).

import { createHash } from "node:crypto";
import type { JSONSchema, QualifiedName } from "@katari-lang/types";
import { createLogger } from "../../lib/logger.js";
import type { PrimRunner } from "../engine/context.js";
import { CALL_ERROR } from "../engine/dynamic-dispatch.js";
import { callableMetadata, conformCallableArgument } from "../engine/interop-prims.js";
import { blobStoreStringReader } from "../engine/json-value.js";
import { createProjectStore } from "../engine/store.js";
import { errorData } from "../engine/throw-signal.js";
import type { BlobEntry } from "../engine/types.js";
import type { ReactorName } from "../event/types.js";
import { type Clock, SystemClock } from "../external/clock.js";
import type { CredentialStore } from "../external/credentials.js";
import type { HttpBlobResolver } from "../external/http-body.js";
import type { HttpBlobProducer, HttpTransport } from "../external/http-transport.js";
import { type McpTransport, StubMcpTransport } from "../external/mcp-transport.js";
import type { FfiTransport } from "../external/runner.js";
import {
  apiRootIdOf,
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newBlobId,
  type ProjectId,
  type SnapshotId,
} from "../ids.js";
import type { IrSource } from "../ir.js";
import type { BlobStore } from "../value/blob-store.js";
import type { Value } from "../value/types.js";
import { renderConformFailures } from "../value/validation.js";
import { ApiReactor, type OpenEscalation } from "./api-reactor.js";
import { CoreReactor } from "./core-reactor.js";
import { isTransientError, messageOf } from "./failure.js";
import { FfiReactor } from "./ffi-reactor.js";
import { HttpReactor } from "./http-reactor.js";
import { McpReactor, type McpServeCallOutcome, type McpServeToolsOutcome } from "./mcp-reactor.js";
import { OauthReactor } from "./oauth-reactor.js";
import type { Persistence } from "./persistence.js";
import type { Reactor } from "./reactor.js";
import { ResourcePool } from "./resource-pool.js";
import { Substrate } from "./substrate.js";
import { TimeReactor } from "./time-reactor.js";
import { type WebhookDeliveryOutcome, WebhookReactor } from "./webhook-reactor.js";

// The api root's run-result error and open-escalation shape live with the ApiReactor now; re-exported here
// so existing importers (tests, callers) keep their entry point.
export { type OpenEscalation, RunCancelledError } from "./api-reactor.js";

/** One tool an `mcp.serve` endpoint advertises: the served record's key as the published name, and the
 *  agent's reflected signature (its declared schemas, still `JSONSchema` — the MCP service lowers them
 *  to the wire shape at its own boundary). */
export interface McpServedToolMetadata {
  name: string;
  description: string;
  input: JSONSchema;
  output: JSONSchema;
}

/** What `listMcpServeTools` resolves to: the advertised tools, or `unknown` for a dead token. */
export type McpServeToolsDescription =
  | { kind: "unknown" }
  | { kind: "tools"; tools: McpServedToolMetadata[] };

export interface ProjectActorDependencies {
  projectId: ProjectId;
  ir: IrSource;
  prims: PrimRunner;
  blobs: BlobStore;
  /** The FFI transport the `ffi` reactor dispatches external handlers through. */
  external: FfiTransport;
  /** The transport the `http` reactor performs built-in `http.fetch` requests through (an in-runtime fetch). */
  http: HttpTransport;
  /** The transport the `mcp` reactor performs built-in `prelude.mcp.*` calls through (the SDK client).
   *  Defaults to the loud stub (fine for tests; the facade injects the SDK-backed one). */
  mcp?: McpTransport;
  /** The public base URL the dynamically generated endpoints are minted under — `webhook.inbound`'s
   *  `<base>/inbound/<token>` and `mcp.serve`'s `<base>/mcp/<token>`. One knob for both: they are the
   *  same public address (KATARI_PUBLIC_URL). Defaults to the local dev address (fine for tests; the
   *  facade injects the configured one). */
  publicBaseUrl?: string;
  /** The wall-clock + timers the `time` reactor reads through (durable `sleep` / `watch`, the `time.now`
   *  reading). Defaults to the real `SystemClock` (fine in production; tests inject a controllable clock so
   *  durable time is deterministic and needs no real waits). */
  clock?: Clock;
  /** The credential store the `oauth` reactor resolves `oauth.token(name)` calls through (the same
   *  `credentials` table the mcp transport reads its bearer from). Defaults to the empty store — every
   *  resolution parks pending authorization — which is fine for tests that never call `oauth.token`. */
  credentials?: CredentialStore;
  persistence: Persistence;
}

/** The empty credential store the `oauth` reactor falls back to when the host wires none: nothing is ever
 *  stored, so every `oauth.token` resolution parks pending authorization. Keeps the actor constructible in
 *  tests that do not exercise OAuth without threading a store through every one. */
const EMPTY_CREDENTIAL_STORE: CredentialStore = {
  async load() {
    return null;
  },
  async save() {
    return false;
  },
  async resolveConfiguredClient() {
    return null;
  },
};

export class ProjectActor {
  private readonly projectId: ProjectId;
  /** The project's permanent `api` management root id (the owner of project-scoped resources — uploaded
   *  files). Derived from the project id — deterministic and stable across restarts. Run delegations are
   *  issued by each run's own permanent run instance, not by this root. */
  private readonly apiRootId: InstanceId;
  private readonly persistence: Persistence;
  /** The IR source, kept for reflection at the actor's own boundaries (a served MCP tool's advertised
   *  metadata resolves through the same `callableMetadata` as `reflection.get_metadata`). */
  private readonly ir: IrSource;

  /** The engine reactor: instances, the delegation routing graph, the IR turns. */
  private readonly core: CoreReactor;
  /** The api management root reactor: the user-facing run / escalation logic. */
  private readonly api: ApiReactor;
  /** The ffi reactor: external (FFI) calls — a `delegate` to it, the transport, its in-flight call records. */
  private readonly ffi: FfiReactor;
  /** The http reactor: built-in `http.fetch` calls — a `delegate` to it, an in-runtime fetch, its records. */
  private readonly http: HttpReactor;
  /** The webhook reactor: `webhook.inbound` calls — dynamically generated public endpoints whose deliveries
   *  become callback delegations. */
  private readonly webhook: WebhookReactor;
  /** The mcp reactor: built-in `prelude.mcp.*` calls — a `delegate` to it, the SDK client, its records. */
  private readonly mcp: McpReactor;
  /** The time reactor: built-in `prelude.time.*` calls — durable `sleep` / `watch` and the `now` reading. */
  private readonly time: TimeReactor;
  /** The oauth reactor: built-in `prelude.oauth.token` calls — on-demand bearer-token resolution, with an
   *  authorization escalation when the named credential needs a human. */
  private readonly oauth: OauthReactor;
  /** The shared scope/blob resource — reset together with the reactors on a poisoned commit. */
  private readonly pool: ResourcePool;
  /** The bus: the serial mailbox + the one atomic commit per turn, routing inbound events by their `to`. */
  private readonly substrate: Substrate;
  /** The injected transports, kept for disposal (their reactors hold them too, but teardown is actor-level). */
  private readonly externalTransport: FfiTransport;
  private readonly httpTransport: HttpTransport;
  private readonly mcpTransport: McpTransport;

  constructor(dependencies: ProjectActorDependencies) {
    this.projectId = dependencies.projectId;
    this.apiRootId = apiRootIdOf(this.projectId);
    this.persistence = dependencies.persistence;
    this.ir = dependencies.ir;
    this.externalTransport = dependencies.external;
    this.httpTransport = dependencies.http;
    this.mcpTransport = dependencies.mcp ?? new StubMcpTransport();
    // The shared scope store + the pool that wraps it: the engine reads / writes scopes in place, while every
    // reactor reowns through the same pool (so a run result crosses from a core instance to the api root).
    const store = createProjectStore();
    this.pool = new ResourcePool(this.projectId, store);
    const pool = this.pool;
    this.core = new CoreReactor(
      this.projectId,
      dependencies.ir,
      dependencies.prims,
      dependencies.blobs,
      store,
      pool,
    );
    // The ffi reactor runs external (FFI) handlers through the injected transport; an external call reaches
    // it as a `delegate` from core's external proxy.
    this.ffi = new FfiReactor(this.projectId, dependencies.external, pool, dependencies.ir);
    // The http reactor performs built-in `http.fetch` calls through the injected transport (an in-runtime
    // fetch); an http call reaches it as a `delegate` from core's external proxy, exactly like ffi.
    this.http = new HttpReactor(dependencies.http, pool);
    // Wire how the http transport materialises a `file` request body: at SEND time it reads the blob's bytes
    // from the store and its content type from the warm catalog (the metadata a slim ref does not carry).
    // Doing it here — from the actor's own blob store + catalog — keeps the bytes off the value plane, the
    // durable call record, and the trace; only the handle ever rides those. A `file` body without this wiring
    // (a bare transport) fails loudly. The content type is read first (a synchronous catalog snapshot), then
    // the immutable, content-addressed bytes are fetched.
    const blobResolver: HttpBlobResolver = async (blobId) => {
      const contentType = store.blobs[blobId]?.contentType ?? "";
      const bytes = await dependencies.blobs.get(this.projectId, blobId);
      return { bytes, contentType };
    };
    dependencies.http.useBlobResolver(blobResolver);
    // Wire how a `fetch_file` RESPONSE becomes a project blob — the receive-side twin of the resolver above.
    // The transport reads the response bytes at the receive boundary; here we store them under a fresh id,
    // hash them (content-addressed, like every produced blob), and register the blob as owned by the http
    // call's instance so the reply's `delegateAck` hoists it to the caller, exactly like an FFI / MCP
    // produced blob. Registering through the serial command turn (`registerProducedBlobOn`) commits the
    // ownership row BEFORE the transport's completion (which carries only the handle) is processed. A
    // vanished call reclaims the orphaned bytes and returns `null`, so the transport drops the download.
    const blobProducer: HttpBlobProducer = async (delegation, bytes, contentType) => {
      const blobId = newBlobId();
      const entry: Omit<BlobEntry, "owner"> = {
        hash: createHash("sha256").update(bytes).digest("hex"),
        size: bytes.byteLength,
        contentType,
        semanticKind: "file",
      };
      await dependencies.blobs.put(this.projectId, blobId, bytes);
      const registered = await this.registerProducedBlobOn(this.http, delegation, blobId, entry);
      if (!registered) {
        // The owning call vanished (cancelled / completed) before its download landed; no row references
        // these bytes, so drop them rather than orphan them — the same fix `mintAndStoreBlob` applies.
        await dependencies.blobs.delete(this.projectId, blobId).catch(() => {});
        return null;
      }
      return blobId;
    };
    dependencies.http.useBlobProducer(blobProducer);
    // The one public base both dynamically generated endpoint kinds mint their capability URLs under.
    const publicBaseUrl = dependencies.publicBaseUrl ?? "http://localhost:3000";
    // The mcp reactor performs built-in `prelude.mcp.*` calls through the injected transport (the SDK
    // client); an mcp call reaches it as a `delegate` from core's external proxy, exactly like http. Its
    // `serve` shape additionally mints inbound endpoints (`<base>/mcp/<token>`) and re-enters the serial
    // loop for its post-commit work through the scheduler closure — which reads `this.substrate`,
    // assigned just below, only when work actually runs.
    this.mcp = new McpReactor(
      this.mcpTransport,
      publicBaseUrl,
      (work) => this.substrate.submit(this.mcp, work),
      // A direct call's argument tree may hold blob-backed string leaves (lowered through the json prims'
      // reader) and `file` leaves (base64'd through the same blob resolver the http body materialiser uses).
      blobStoreStringReader(this.projectId, dependencies.blobs),
      blobResolver,
      pool,
    );
    // The webhook reactor serves `webhook.inbound` calls: it mints tokens and re-enters the serial loop for
    // its post-commit work (the subscriber dispatch, synthesised completions) the same way.
    this.webhook = new WebhookReactor(
      publicBaseUrl,
      (work) => this.substrate.submit(this.webhook, work),
      pool,
    );
    // The time reactor serves `prelude.time.*` calls: it reads the injected clock and arms its durable timers,
    // re-entering the serial loop for a fired timer's post-commit work (a resolve, a watch tick) the same way.
    this.time = new TimeReactor(
      dependencies.clock ?? new SystemClock(),
      (work) => this.substrate.submit(this.time, work),
      pool,
    );
    // The oauth reactor resolves `prelude.oauth.token` calls through the credential store, re-entering the
    // serial loop for its post-commit work (an async token resolution's settle / park / throw) the same way.
    this.oauth = new OauthReactor(
      dependencies.credentials ?? EMPTY_CREDENTIAL_STORE,
      (work) => this.substrate.submit(this.oauth, work),
      pool,
    );
    // The api root schedules each command (start / cancel / answer) onto the bus as a serial command turn;
    // the closure reads `this.substrate`, assigned just below, only when a command actually runs.
    this.api = new ApiReactor(
      this.apiRootId,
      { enqueue: (thunk) => this.substrate.enqueueCommand(this.api, thunk) },
      pool,
    );
    const registry: Record<ReactorName, Reactor> = {
      core: this.core,
      api: this.api,
      ffi: this.ffi,
      http: this.http,
      webhook: this.webhook,
      mcp: this.mcp,
      time: this.time,
      oauth: this.oauth,
    };
    this.substrate = new Substrate(
      this.projectId,
      this.persistence,
      registry,
      pool,
      dependencies.blobs,
      {
        reactivate: () => this.reactivate(),
        onPoison: (error) =>
          this.api.poisonRunPromises(
            error instanceof Error
              ? new Error(`run tracking reset after a commit failure: ${error.message}`)
              : new Error(
                  "run tracking reset after a commit failure; query the run's durable state",
                ),
          ),
      },
      createLogger({ level: "info", bindings: { module: "substrate", projectId: this.projectId } }),
    );
    // An FFI transport completion re-enters through the same serial mailbox as every other turn, as a ffi
    // reactor turn that turns it into the call's delegateAck / escalate / terminateAck.
    dependencies.external.onComplete((completion) =>
      this.substrate.submit(this.ffi, () => this.ffi.complete(completion)),
    );
    // A running handler's inner agent call enters the same way, as a ffi reactor turn that opens an ordinary
    // `delegate` (to core by default, or another call reactor) under the in-flight call's instance.
    dependencies.external.onDelegate((request) =>
      this.substrate.submit(this.ffi, () => this.ffi.innerDelegate(request)),
    );
    // An http transport completion re-enters the same way, as an http reactor turn that turns it into the
    // call's delegateAck / escalate / terminateAck.
    dependencies.http.onComplete((completion) =>
      this.substrate.submit(this.http, () => this.http.complete(completion)),
    );
    // An mcp transport completion re-enters the same way, as an mcp reactor turn.
    this.mcpTransport.onComplete((completion) =>
      this.substrate.submit(this.mcp, () => this.mcp.complete(completion)),
    );
  }

  // ─── api root commands (exposed for in-process callers; the logic lives in the ApiReactor) ──────────

  /** Start a run. The run id is its permanent run instance's id (the durable handle); `result` is an
   *  in-process convenience; `started` resolves once the launch (instance + `runs` metadata + delegation +
   *  delegate) is durably committed. `name` is the run's human label (defaults to the qualified name). */
  startRun(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
    name?: string,
  ): { run: InstanceId; result: Promise<Value>; started: Promise<void> } {
    return this.api.startRun(qualifiedName, snapshot, argument, name ?? qualifiedName);
  }

  /** Validate a run's entry at the run-start boundary — the run-start API is an external input boundary like
   *  a webhook, so BOTH an unresolvable entry agent AND a malformed argument are rejected (a 400) BEFORE the
   *  run starts, rather than reaching core's acceptance surface as a pre-birth panic whose raiser would be
   *  the PERMANENT run instance (which must never own an ephemeral escalation row — it is the run's result
   *  container). Returns a rejection message, or `null` when the entry resolves and the argument conforms.
   *  A *transient* resolution failure (an IR-store read blip) is NOT a rejection but must NOT defer-and-launch
   *  either: launching an UNVALIDATED run would let a deterministic pre-birth failure at core wedge it (its
   *  raiser being the permanent run instance, whose loud throw drops the delegate). So the transient error is
   *  rethrown for the caller to surface as retryable (a 503) — the run is never launched unvalidated. */
  async conformRunArgument(
    qualifiedName: QualifiedName,
    snapshot: SnapshotId,
    argument: Value | null,
  ): Promise<string | null> {
    try {
      // A private agent is handle-private: the compiler permits a call to it only from within a private
      // world, and the run-start API is the runtime's operator-facing boundary — outside any world — so
      // starting one here would surface its private escalations to the operator. Refuse it up front, the
      // same 400 an unresolvable entry gets. Delegation / first-class resolution still resolve the entry
      // (the block is untouched), so only this boundary is closed. `preload` first, so `locate` (a sync
      // read of the loaded snapshot) can see the entry; a transient preload failure funnels through the
      // catch as retryable, exactly as `conformCallableArgument`'s own preload would.
      await this.ir.preload(snapshot);
      if (this.ir.locate(snapshot, qualifiedName).private) {
        return `the agent ${qualifiedName} is private and cannot be started from the runtime boundary`;
      }
      const failures = await conformCallableArgument(
        { kind: "agent", name: qualifiedName, snapshot },
        argument,
        this.ir,
      );
      return failures === null
        ? null
        : `the run argument does not conform to ${qualifiedName}'s input schema — ${renderConformFailures(failures)}`;
    } catch (error) {
      // A transient IR-store blip is retryable — rethrow it (the caller maps it to a 503) rather than defer,
      // which would launch an unvalidated run. A deterministic failure means the entry does not exist → 400.
      if (isTransientError(error)) throw error;
      return `the entry agent ${qualifiedName} cannot be resolved: ${messageOf(error)}`;
    }
  }

  /** Request a run's cancellation (terminate cascade + durable cancel reason). Resolves once the cancel
   *  commit is durable; a no-op in the engine if the run already finished. */
  cancelRun(run: InstanceId, reason?: string): Promise<void> {
    return this.api.cancelRun(run, reason);
  }

  /** Answer an open run-root escalation, resuming its suspended raiser. */
  answerEscalation(escalation: EscalationId, value: Value): Promise<void> {
    return this.api.answerEscalation(escalation, value);
  }

  /** Register a freshly uploaded file as an api-root-owned blob (bytes already in the BlobStore). Resolves
   *  once the blob row is durably committed. */
  uploadBlob(blobId: BlobId, entry: Omit<BlobEntry, "owner">): Promise<void> {
    return this.api.registerUploadedBlob(blobId, entry);
  }

  /** Delete an uploaded file's api-root-owned blob (its row in the delete commit, its bytes strictly after).
   *  Resolves once the delete commit is durable — to `false` when the project holds no such file. */
  deleteBlob(blobId: BlobId): Promise<boolean> {
    return this.api.deleteUploadedBlob(blobId);
  }

  /** Register a blob an FFI handler produced mid-call as owned by that call's instance (bytes already in
   *  the BlobStore) — so the call's return ascends it to the core caller, and a handler that dies before
   *  returning has it reclaimed at teardown. See `registerProducedBlobOn` for the commit contract. */
  registerProducedBlob(
    delegation: DelegationId,
    blobId: BlobId,
    entry: Omit<BlobEntry, "owner">,
  ): Promise<boolean> {
    return this.registerProducedBlobOn(this.ffi, delegation, blobId, entry);
  }

  /** Like `registerProducedBlob`, for a blob the MCP transport produced from a tool result's image
   *  content: owned by that mcp call's instance, so the result's `delegateAck` ascends it to the caller. */
  registerProducedMcpBlob(
    delegation: DelegationId,
    blobId: BlobId,
    entry: Omit<BlobEntry, "owner">,
  ): Promise<boolean> {
    return this.registerProducedBlobOn(this.mcp, delegation, blobId, entry);
  }

  /** The shared contract behind the produced-blob entry points — the FFI handler's mid-call upload, the MCP
   *  tool result's image, and the `http.fetch_file` download's blob producer (they differ only in which call
   *  reactor owns the delegation): run as a serial command turn so the ownership row commits durably before
   *  the transport's completion (which carries the blob's handle in its result) is processed. Resolves to
   *  whether the blob was registered — `false` when the call already vanished, so the caller can delete
   *  the orphaned bytes. */
  private registerProducedBlobOn(
    reactor: FfiReactor | McpReactor | HttpReactor,
    delegation: DelegationId,
    blobId: BlobId,
    entry: Omit<BlobEntry, "owner">,
  ): Promise<boolean> {
    let registered = false;
    return this.substrate
      .enqueueCommand(reactor, () => {
        registered = reactor.registerProducedBlob(delegation, blobId, entry);
      })
      .then(() => registered);
  }

  /** The run-root escalations currently awaiting an answer. */
  listOpenEscalations(): OpenEscalation[] {
    return this.api.listOpenEscalations();
  }

  /** Deliver one inbound webhook POST to the endpoint serving `token`: the webhook reactor converts it into
   *  a delegation of the endpoint's callback on a serial turn, and the returned promise resolves with the
   *  callback's outcome (or `unknown` / `gone` for a dead endpoint) once it settles. The body is
   *  pre-validated against the callback's declared input schema first, so a MALFORMED delivery is a
   *  per-request 400 and the endpoint keeps serving — only a genuine failure while the callback RUNS proxies
   *  up and drops the endpoint. */
  async deliverWebhook(token: string, argument: Value): Promise<WebhookDeliveryOutcome> {
    const callback = await this.webhookCallbackOf(token);
    if (callback !== undefined) {
      const rejection = await this.boundaryRejection(callback, argument);
      if (rejection !== null) return { kind: "throw", value: rejection };
    }
    return new Promise((resolve) => {
      this.substrate.submit(this.webhook, () => this.webhook.deliver(token, argument, resolve));
    });
  }

  /** The callback value the webhook endpoint serving `token` holds, read on a serial turn — the seam the
   *  delivery pre-validation resolves the declared input schema from (the actor resolves schemas, a reactor
   *  turn cannot await), mirroring how the mcp listing reads its served entries. */
  private webhookCallbackOf(token: string): Promise<Value | undefined> {
    return new Promise((resolve) => {
      this.substrate.submit(this.webhook, () => resolve(this.webhook.callbackFor(token)));
    });
  }

  /** Pre-validate an external delivery / run argument against a served callable's DECLARED input schema (the
   *  same `callableMetadata` seam the mcp listing uses). Returns the `reflection.call_error` value to answer
   *  the request with on a mismatch — which each user-facing boundary maps to its own 400 / invalid-params —
   *  or `null` when the argument conforms. A genuine failure while the callee RUNS is a separate concern (it
   *  proxies up); this catches only a malformed request before anything runs. */
  private async boundaryRejection(value: Value, argument: Value | null): Promise<Value | null> {
    let failures: Awaited<ReturnType<typeof conformCallableArgument>>;
    try {
      failures = await conformCallableArgument(value, argument, this.ir);
    } catch {
      // A served value that is not callable / cannot be resolved: we cannot pre-validate it, so fall through
      // to the reactor's own dispatch — which rejects it gracefully as a per-request error — rather than let
      // the resolution throw surface as a 500. (Mirrors `dispatchCallable`'s own gracefulness.)
      return null;
    }
    return failures === null
      ? null
      : errorData(
          CALL_ERROR,
          `the argument does not conform to the input schema — ${renderConformFailures(failures)}`,
        );
  }

  /** Whether a live `mcp.serve` endpoint holds `token` — the MCP `initialize` liveness probe (cheap: the
   *  reactor read runs on a serial turn, no metadata is resolved). */
  async probeMcpServe(token: string): Promise<boolean> {
    const outcome = await this.mcpServeToolEntries(token);
    return outcome.kind === "tools";
  }

  /** The tools a live `mcp.serve` endpoint advertises, for MCP `tools/list`: each served record entry's
   *  metadata resolved through the same `callableMetadata` as `reflection.get_metadata` — the record key
   *  is the published name (overriding the callee's own), the schemas are the agent's declared signature. */
  async listMcpServeTools(token: string): Promise<McpServeToolsDescription> {
    const outcome = await this.mcpServeToolEntries(token);
    if (outcome.kind === "unknown") return { kind: "unknown" };
    const tools: McpServedToolMetadata[] = [];
    for (const entry of outcome.entries) {
      const metadata = await callableMetadata(entry.value, this.ir);
      tools.push({
        name: entry.name,
        description: metadata.description,
        input: metadata.input,
        output: metadata.output,
      });
    }
    return { kind: "tools", tools };
  }

  /** Deliver one MCP `tools/call` to the endpoint serving `token`: the mcp reactor converts it into a
   *  delegation of the served record's agent on a serial turn, and the returned promise resolves with
   *  the agent's outcome (or the dead-endpoint / unknown-tool variants) once it settles. */
  async deliverMcpServeCall(
    token: string,
    tool: string,
    argument: Value,
  ): Promise<McpServeCallOutcome> {
    // Pre-validate the argument against the served tool's declared input schema (resolved actor-side through
    // the same `callableMetadata` seam as the listing). A malformed call is a per-request invalid-params and
    // the endpoint keeps serving; a genuine failure while the tool RUNS still proxies up. An unknown token /
    // tool falls through to `serveCall`, which answers it.
    const entries = await this.mcpServeToolEntries(token);
    if (entries.kind === "tools") {
      const entry = entries.entries.find((candidate) => candidate.name === tool);
      if (entry !== undefined) {
        const rejection = await this.boundaryRejection(entry.value, argument);
        if (rejection !== null) return { kind: "throw", value: rejection };
      }
    }
    return new Promise((resolve) => {
      this.substrate.submit(this.mcp, () => this.mcp.serveCall(token, tool, argument, resolve));
    });
  }

  /** The reactor-side read behind the two listing entry points: the served record's entries, resolved
   *  on a serial turn (a pure read — the turn only guarantees a consistent view of the warm calls). */
  private mcpServeToolEntries(token: string): Promise<McpServeToolsOutcome> {
    return new Promise((resolve) => {
      this.substrate.submit(this.mcp, () => resolve(this.mcp.serveTools(token)));
    });
  }

  /** Activate a (possibly recovered) actor: reload persisted state and reconcile in-flight external work,
   *  without an inbound message to trigger it. Idempotent — the warm actor also self-activates on its first
   *  command; a host calls this on boot to resume a project whose process went down mid-flight. */
  async activate(): Promise<void> {
    await this.substrate.activate();
  }

  /** Tear the actor down (the project is being deleted): kill the FFI sidecar processes, abort in-flight
   *  http requests, and reject the in-process run promises so nothing hangs. Durable state is the caller's
   *  concern (the project row's delete cascade); a disposed actor must simply stop working — it is dropped
   *  from the registry and never used again. */
  dispose(): void {
    this.externalTransport.close();
    this.httpTransport.close();
    this.mcpTransport.close();
    this.api.poisonRunPromises(new Error("the project was deleted"));
  }

  // ─── reactivation (the substrate's domain half) ─────────────────────────────────────────────────

  /** Lazily reload the project's persisted state on first use: each reactor pulls only the rows it owns from
   *  the loader (core its engine graph + routing + its delegations/escalations; the api root its run
   *  delegations + answerable escalations; the ffi reactor its in-flight calls, which it reconciles) —
   *  no central blob, no cross-reactor classification. The undrained outbox is replayed into the mailbox.
   *  The api management root's durable `instances` row is ensured by the api reactor in each run's
   *  `delegate` commit (it owns that row), so reactivation only reads. */
  private async reactivate(): Promise<void> {
    // Reactivation is idempotent and is the recovery path after a poisoned commit too: drop any warm state
    // first (a cold start clears empty state — a no-op), so reloading never accumulates stale routing.
    this.core.reset();
    this.api.reset();
    this.ffi.reset();
    this.http.reset();
    this.webhook.reset();
    this.mcp.reset();
    this.time.reset();
    this.oauth.reset();
    this.pool.reset();
    await this.persistence.load(this.projectId, async (loader) => {
      // The reactors read disjoint durable state through the loader, so the pure-read loads run concurrently.
      await Promise.all([this.core.load(loader), this.api.load(loader)]);
      // The ffi / http loads reconcile their in-flight calls with their transports (a side effect), so they
      // run only after the pure reads have succeeded — but concurrently with each other. Both are
      // at-most-once: work the transport still holds is left running (a warm reset), gone work fails as a
      // panic (never re-run), a cancelling call re-aborts.
      // The webhook load re-registers each endpoint's token — no external process to reconcile with, so
      // (unlike ffi / http) a webhook call survives a restart completely.
      // The time load re-arms each call's durable timer (a passed deadline fires at once) — like webhook,
      // there is no external process to reconcile, so a time call survives a restart completely.
      // The oauth load, like time, has no external process to reconcile: a reloaded resolution re-resolves
      // (at-most-once-safe), and a parked call reconstructs from its open authorize escalation row.
      await Promise.all([
        this.ffi.load(loader),
        this.http.load(loader),
        this.webhook.load(loader),
        this.mcp.load(loader),
        this.time.load(loader),
        this.oauth.load(loader),
      ]);
      // Replay the undrained outbox: events produced before the crash but not yet consumed.
      for (const message of await loader.outbox.pending()) {
        this.substrate.enqueueOutbox(message.event, message.seq);
      }
    });
  }
}
