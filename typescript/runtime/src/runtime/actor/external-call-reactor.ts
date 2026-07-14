// ExternalCallReactor: the shared base for the reactors that own external *callee* calls over a transport —
// `ffi` (the sidecar) and `http` (the built-in client). Both receive a call as a `delegate` routed from
// core's `ExternalThread` proxy, dispatch it through their transport, and turn the transport's completion
// into the call's `delegateAck` (result), an `escalate` (a no-result error → a panic), or a `terminateAck`
// (an abort confirmed). The whole per-delegation callee-instance lifecycle — the call map, the caller it
// replies to, the running / cancelling / awaitingAnswer state machine, the envelope + extension persistence,
// and the at-most-once-shaped recovery — lives here once; a concrete reactor supplies only its
// transport-specific bits (how to dispatch / abort / settle an inner call) plus a per-call payload and the
// extension codec that round-trips that payload with the durable extension document.
//
// A call is also a *caller*: its handler can ask the runtime to call another agent (an inner delegation —
// the generic agent-call channel). The base owns that whole protocol too, symmetric to a core instance's
// sub-calls:
//   - `openInnerDelegation` issues an ordinary `delegate` (caller = the call's instance; the base reactor
//     opens the caller-owned row), correlated to the transport's `call` token in the durable `innerCalls`
//     bridge so a settled result still finds its consumer after a warm reset.
//   - a child's `delegateAck` / `terminateAck` retires the row (base), re-owns the result's resources onto
//     the call's instance, and stages a post-commit delivery through the concrete's `deliverInnerOutcome`.
//   - a child's `escalate` is proxied UP under the call's own delegation with a fresh escalation id (the
//     `relays` bridge, durable on the call row), and the answering `escalateAck` is proxied back DOWN —
//     the transport never sees escalations, so a sidecar handler needs no escalation protocol of its own.
//   - a `terminate` from above is distributed to the call's live children, and the upward `terminateAck`
//     waits until the transport confirmed AND every child drained (the graceful-cancel barrier, exactly
//     like a core instance's cancel cascade).
//
// A call's lifecycle: running (transport in flight) → result / error / cancel. A completion that lands while
// the callee still has live children is HELD (in memory — after a crash the reload converges to the same
// shape, the refused call's error cancelling the children the same way) and the children are cancelled
// first, so a resolved call never leaves in-transit resources behind. On an error the call does not finish —
// like a panicking sub-call it escalates the panic and waits (`awaitingAnswer`) for either an `escalateAck`
// (a handler caught it — the answer becomes the result) or a `terminate` (unhandled — the run is failing).
// The process/request has stopped, so that wait needs no transport.
//
// Execution is AT-MOST-ONCE: the runtime never re-runs external work (see `recover`) — a call whose process
// died fails as a panic, and whether to retry is a katari-level decision, not the runtime's.

import type { Json } from "@katari-lang/types";
import type { ExternalCallStatus } from "../../db/tables/execution.js";
import type { BlobEntry } from "../engine/types.js";
import type { DelegateTarget, ExternalEvent, ReactorName } from "../event/types.js";
import {
  type BlobId,
  type DelegationId,
  type EscalationId,
  type InstanceId,
  newDelegationId,
  newEscalationId,
  newInstanceId,
} from "../ids.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import { messageOf } from "./failure.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { Reactor } from "./reactor.js";

/** The `external` delegate target (the only kind that routes to a call reactor) — the shape `openPayload`
 *  reads a fresh call's transport parameters from. */
export type ExternalTarget = Extract<DelegateTarget, { kind: "external" }>;

/** The lifecycle state of an in-flight call: `running` (transport in flight), `cancelling` (aborting, awaiting
 *  the transport's stop and the children's drain), or `awaitingAnswer` (transport errored, panic escalated,
 *  awaiting a caught-panic answer or the run's terminate). The same union the durable row stores
 *  (`external_call_instances.status` — one SoT for the vocabulary). */
export type CallStatus = ExternalCallStatus;

/** A completion fed back from a transport (the ffi / http completion shape, structurally shared): a `result`
 *  (→ delegateAck), a `throw` (a typed `prelude.throw` the reactor escalates with `error` as its decoded
 *  payload), an `error` (no result → a panic the reactor escalates), or a `cancelled` confirmation
 *  (→ terminateAck, after an `abort`). A late completion for a resolved call is harmless (guarded). */
export interface ExternalCompletion {
  delegation: DelegationId;
  outcome:
    | { kind: "result"; value: Json }
    | { kind: "throw"; error: Json }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One escalation this reactor is proxying upward for a call: the outer id it re-raised the ask under (the
 *  row key), and the child leg its answer descends to. Durable in the call's extension document, so an
 *  in-flight answer still routes down after a restart. */
export interface EscalationRelayRow {
  escalation: EscalationId;
  child: DelegationId;
  childEscalation: EscalationId;
}

/** One inner delegation's transport correlation: the delegation the base opened, and the transport's own
 *  `call` token its settled outcome is delivered under. Durable in the call's extension document, so a
 *  result landing after a warm reset still reaches its consumer (only a transport-process death makes it
 *  stale — the call is then failing anyway, and the stale delivery is dropped). */
export interface InnerCallRow {
  delegation: DelegationId;
  call: string;
}

/** A settled inner delegation on its way to the transport: the parent call's `delegation`, the transport's
 *  `call` token, and the outcome. Since a callee's failure now proxies UP (it no longer settles the inner
 *  call — see `onEscalate`), only a `result` (still an engine `Value`; the concrete lowers it at its own
 *  boundary, e.g. revealing secrets to the FFI sidecar) or a `cancelled` ever rides this path; the `error`
 *  arm is a defensive residue for a designated-inner-delegation reactor that synthesises one. */
export interface InnerDelivery {
  delegation: DelegationId;
  call: string;
  outcome:
    | { kind: "result"; value: Value }
    | { kind: "error"; message: string }
    | { kind: "cancelled" };
}

/** One in-flight call's state, keyed by its delegation. Its instance id (the issuer of its replies) and its
 *  caller (the reply-to) are NOT here — they are the received-delegation edge, held once in the base
 *  `handled` index (added / dropped alongside this entry). `relays` is durable (the extension document);
 *  the two hold-state fields are in-memory only — a reload reproduces them (`transportSettled` by
 *  re-aborting, `pendingOutcome` by the recovery outcome the transport reports). */
interface Call<Payload> {
  status: CallStatus;
  payload: Payload;
  relays: Map<EscalationId, { child: DelegationId; escalation: EscalationId }>;
  /** While cancelling: whether the transport confirmed the abort (the other half of the ack barrier). */
  transportSettled: boolean;
  /** A completion that landed while children were still live — applied once they drain. */
  pendingOutcome: ExternalCompletion["outcome"] | undefined;
}

/** What a concrete reactor's extension codec encodes for one call — its transport payload plus the two
 *  inner-delegation bridges (the base maintains them; the codec decides where they ride in the document).
 *  The caller (reply-to) / run / status are NOT here: they are the envelope's and the row's own columns. */
export interface CallRow<Payload> {
  instance: InstanceId;
  delegation: DelegationId;
  status: CallStatus;
  payload: Payload;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** What a concrete reactor's extension codec decodes back out of one reloaded call's document: the warm
 *  payload and the bridges. The envelope half (delegation / instance / caller / run) and the status come
 *  from the row itself, so the base re-seeds those uniformly. */
export interface DecodedCallExtension<Payload> {
  payload: Payload;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** The ONE ack-shaping seam a call payload may carry: decoding its own `delegateAck` value straight from
 *  the transport's RAW wire Json. A plain-data payload omits it and the base wire decoder (`jsonToValue`)
 *  runs; a payload whose result is assembled FROM the call attaches it where its variant is decided
 *  (`openPayload`) — the mcp direct call decodes the raw reply against its result generic `T`: a typed `T`
 *  reconstructs the value wire form (a `$ref` becomes a REAL `file`), while `json.json` keeps the raw
 *  reply as a literal `json` tree. Shaping at the WIRE boundary (raw Json in, Value out) keeps hostile /
 *  quirky server Json away from the generic decoder, which is total only for wire-shaped documents. A
 *  reply the direct call cannot decode against `T` is turned into a typed `decode_error` throw in the
 *  reactor's own `complete`, BEFORE this seam runs — the seam that builds the value cannot itself throw. */
export interface AckDecodingPayload {
  decodeAck?: (raw: Json) => Value;
}

/** Read a payload's optional ack decoder structurally. The class's payload parameter is constrained only to
 *  `object` because constraining it to the all-optional `AckDecodingPayload` would trip TypeScript's
 *  weak-type check for the plain-data payloads (ffi / http / webhook) that share no field with it. */
function ackDecoderOf(payload: object): ((raw: Json) => Value) | undefined {
  const decoding: AckDecodingPayload = payload;
  return decoding.decodeAck;
}

export abstract class ExternalCallReactor<Payload extends object> extends Reactor {
  /** In-flight calls (warm SoT) keyed by their delegation, plus the per-turn dirty set `persist` upserts and
   *  the instance ids of calls resolved this turn (their envelopes are dropped, cascading the extension row). */
  private readonly calls = new Map<DelegationId, Call<Payload>>();
  /** The reverse of the base received edge: a call's instance back to its delegation — how an inner
   *  delegation's reply (whose base-resolved context names the caller *instance*) finds its parent call. */
  private readonly callByInstance = new Map<InstanceId, DelegationId>();
  /** The durable inner-call bridge: an inner delegation to the transport token its outcome settles. */
  private readonly innerCalls = new Map<DelegationId, { parent: DelegationId; call: string }>();
  /** The reverse of `innerCalls`: a parent call's delegation to the set of its live inner-delegation ids, so
   *  `innerCallRowsOf` (persist) and the orphan-bridge sweep in `drop` read one bucket instead of scanning
   *  every reactor-wide bridge. Maintained alongside `innerCalls`. */
  private readonly innerCallsByParent = new Map<DelegationId, Set<DelegationId>>();
  /** Outcomes settled this turn, delivered to the transport strictly post-commit (durable-first). */
  private pendingDeliveries: InnerDelivery[] = [];
  private readonly dirty = new Set<DelegationId>();
  private droppedInstances: InstanceId[] = [];
  /** The blobs each in-flight call produced mid-call (via `registerProducedBlob`), owned by the call's
   *  instance. At a successful completion the base adopts onto the run any of these the result did NOT
   *  ascend by value — the NARROW backstop for a direct mcp call decoded to a raw `json` tree (`T =
   *  json.json`), where a produced blob's `$ref` rides as an inert STRING leaf, not a real ref, so the
   *  value-driven release never freed it and this call's drop would otherwise reclaim it in the same
   *  commit that delivered the result. A typed decode reconstructs a REAL ref, which ascends by value and
   *  needs no adoption. In-memory only: recovery is at-most-once, so an interrupted call fails and its
   *  produced blobs reclaim at its drop. */
  private readonly producedBlobs = new Map<DelegationId, Set<BlobId>>();

  // ─── concrete-reactor hooks (the only transport-specific surface) ────────────────────────────────

  /** Build the per-call payload (the call's transport data) for a fresh delegate. `generics` is the
   *  external agent's own instantiation (the call site's stamped substitution) — how a reactor that
   *  decodes its reply against a result generic reaches that schema; a reactor with no such generic
   *  ignores it. */
  protected abstract openPayload(
    target: ExternalTarget,
    argument: Value | null,
    generics: GenericSubstitution | undefined,
  ): Payload;

  /** Dispatch a fresh call to the transport (always means "run it"). */
  protected abstract dispatch(delegation: DelegationId, payload: Payload): void;

  /** Reconcile a reloaded in-flight call with the transport (at-most-once; never starts work): work the
   *  transport still has running is left alone (a warm reset — its completion will come), gone work fails
   *  with an `error` completion → a panic katari code can catch and retry. The runtime never re-runs
   *  external work on its own. */
  protected abstract recover(delegation: DelegationId): void;

  /** Abort an in-flight call — a post-commit `terminate`, or a `cancelling` call recovered after a crash. The
   *  transport confirms with a `cancelled` completion (synthesising one when the request is already gone). */
  protected abstract abort(delegation: DelegationId): void;

  /** Encode one call's kind-specific reconstruction material as its extension document. Delegates to the
   *  reactor's pure `encode…Extension` codec; the hook itself may consult reactor state to pick the
   *  document's variant (the mcp park). The base writes the document through `tx.external` and seals it
   *  uniformly — the codec never sees the seal. */
  protected abstract encodeCallExtension(row: CallRow<Payload>): Json;

  /** Decode one reloaded call's extension document back into its warm payload + bridges — the pure
   *  `decode…Extension` codec's inverse of the above. */
  protected abstract decodeCallExtension(extension: Json): DecodedCallExtension<Payload>;

  /** The public capability token a call mints, if this kind mints one (webhook / mcp-serve). The base
   *  maintains the `capability_routes` index row in the same commit as the call row, so cold inbound
   *  routing can never observe a token without its route. `null` — the default — writes no route. */
  protected capabilityTokenOf(_payload: Payload): string | null {
    return null;
  }

  /** Deliver one settled inner delegation to the transport (strictly post-commit). Default no-op: a reactor
   *  whose transport never opens inner delegations (http) never has one staged. */
  protected deliverInnerOutcome(_delivery: InnerDelivery): void {}

  /** A call resolved and is being dropped — a concrete reactor releases the per-call state it indexes
   *  outside the base (the webhook reactor's token registry). Default no-op. */
  protected onDropCall(_delegation: DelegationId): void {}

  /** The instance handling `delegation`, or `undefined` — for a concrete reactor that owns per-call resources
   *  (an ffi call's produced blob) to attribute them to the right instance. Reads the base received edge. */
  protected callInstance(delegation: DelegationId): InstanceId | undefined {
    return this.handledInstanceOf(delegation);
  }

  /** Register a blob this call's transport produced mid-call (its bytes already in the `BlobStore`) as owned
   *  by the call's instance — so the call's `delegateAck` ascends it to the caller through the base reactor's
   *  release / reown, exactly like a core sub-call's result blob. An ffi handler produces one over the blob
   *  side channel; an mcp tool result's image content produces one at the transport seam. Returns whether it
   *  took: `false` when the call is already gone (cancelled / completed), so the caller can delete the
   *  just-stored bytes — which have no row referencing them — rather than orphan them. */
  registerProducedBlob(
    delegation: DelegationId,
    blobId: BlobId,
    entry: Omit<BlobEntry, "owner">,
  ): boolean {
    const instance = this.callInstance(delegation);
    if (instance === undefined) return false;
    this.pool.registerBlob(blobId, { owner: instance, ...entry });
    const produced = this.producedBlobs.get(delegation);
    if (produced === undefined) this.producedBlobs.set(delegation, new Set([blobId]));
    else produced.add(blobId);
    return true;
  }

  /** The transport payload of a live call — a concrete reactor reads a fresh inner delegation's ambient
   *  (e.g. the snapshot the parent call was dispatched against) from it. */
  protected payloadOf(delegation: DelegationId): Payload | undefined {
    return this.calls.get(delegation)?.payload;
  }

  /** The lifecycle status of a live call, or `undefined` once resolved — for a concrete reactor whose
   *  transport signals something outside the four base outcomes (the mcp park) to decide whether the call
   *  can still be acted on, without owning a parallel status map. */
  protected callStatusOf(delegation: DelegationId): CallStatus | undefined {
    return this.calls.get(delegation)?.status;
  }

  /** Whether `escalation` is one this call is RELAYING upward for an inner delegation's child ask (a
   *  `relays` bridge entry), as opposed to an ask the call raised for itself. A concrete reactor that
   *  raises its own asks under a call's delegation (the mcp authorize park) needs the distinction on
   *  reload: both faces are open rows with the same delegation and request name, but a relayed one must
   *  descend through the bridge when answered, never resume the call itself. */
  protected hasEscalationRelay(delegation: DelegationId, escalation: EscalationId): boolean {
    return this.calls.get(delegation)?.relays.has(escalation) ?? false;
  }

  /** Stage a live call's row for re-persist this turn — for a concrete reactor whose OWN durable state on
   *  the row changed outside the base's mutations (the mcp park flips its extension variant). A no-op for
   *  a resolved call (its drop supersedes any upsert). */
  protected markCallDirty(delegation: DelegationId): void {
    if (this.calls.has(delegation)) this.dirty.add(delegation);
  }

  /** The instance + caller (reply-to) + run (trace context) of a live call, read from the base
   *  received-delegation edge. Present for any delegation this reactor still holds a `calls` entry for — the
   *  edge and the entry are added (delegate) and dropped (resolve) together, so a missing edge here is a
   *  bug, surfaced loudly rather than papered over. */
  private routeOf(delegation: DelegationId): {
    instance: InstanceId;
    caller: ReactorName;
    run: InstanceId;
  } {
    const instance = this.handledInstanceOf(delegation);
    const caller = this.handledCallerOf(delegation);
    const run = this.handledRunOf(delegation);
    if (instance === undefined || caller === undefined || run === undefined) {
      throw new Error(`${this.name} holds a call for ${delegation} with no received edge (bug)`);
    }
    return { instance, caller, run };
  }

  // ─── inner delegations (the callee calling other agents) ────────────────────────────────────────

  /** Open an inner delegation from a live call: issue an ordinary `delegate` with the call's instance as its
   *  caller (the base opens the caller-owned row) and bridge it to the transport's `call` token. `generics`
   *  is the callee value's resolved instantiation (a `value` callee carries its own), recorded as the new
   *  instance's ambient substitution. Returns the delegation id, or `null` when the call cannot accept new
   *  work (gone, cancelling, or already settled) — the concrete then fails the token back to the transport. */
  protected openInnerDelegation(
    parent: DelegationId,
    target: DelegateTarget,
    to: ReactorName,
    argument: Value | null,
    call: string,
    generics?: GenericSubstitution,
  ): DelegationId | null {
    const parentCall = this.calls.get(parent);
    if (
      parentCall === undefined ||
      parentCall.status !== "running" ||
      parentCall.pendingOutcome !== undefined
    ) {
      return null;
    }
    const { instance, run } = this.routeOf(parent);
    const delegation = newDelegationId();
    this.innerCalls.set(delegation, { parent, call });
    this.indexInnerCall(parent, delegation);
    this.dirty.add(parent);
    // An inner delegation stays inside the parent call's run — its trace context is the call's ambient.
    this.send(
      {
        kind: "delegate",
        delegation,
        target,
        argument,
        ...(generics !== undefined ? { generics } : {}),
        from: this.name,
        to,
        run,
      },
      instance,
    );
    return delegation;
  }

  /** An inner delegation returned: the base has retired the caller-owned row; re-own the result's resources
   *  onto the call's instance (they are reclaimed at its drop unless its own result ascends them), stage the
   *  post-commit delivery, and settle the call if this was the last thing it waited on. */
  protected onDelegateAck(
    event: Extract<ExternalEvent, { kind: "delegateAck" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined || context.caller === undefined) return; // the call is gone — an undeliverable result
    this.reownIncoming(event.value, context.caller);
    this.stageInnerDelivery(parent, event.delegation, { kind: "result", value: event.value });
    this.maybeSettle(parent);
  }

  /** An inner delegation's cancel confirmed (the terminate this reactor distributed): the base has retired
   *  the row; tell the transport (so an awaiting handler unwinds) and settle the call if fully drained. */
  protected onTerminateAck(
    event: Extract<ExternalEvent, { kind: "terminateAck" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined || context.caller === undefined) return;
    this.stageInnerDelivery(parent, event.delegation, { kind: "cancelled" });
    this.maybeSettle(parent);
  }

  /** An inner delegation escalated. This reactor intercepts NOTHING of its child's escalations — a callee's
   *  failure is not caught here in JS. EVERY ask (a PANIC, a `prelude.throw`, a user-facing request, a
   *  control escape) is proxied UP under the call's own delegation with a fresh escalation id, bridged in
   *  `relays` so the answer descends the same path; the transport never sees it (the effect-handler ideal:
   *  intercept nothing, proxy all). A callee's panic/throw therefore unwinds up like any escalate — caught
   *  by a katari-side handler above (a throw handler) or, uncaught, failing the run — rather than settling
   *  the inner call as a failure a JS `context.call` could catch. The dead callee is torn down not by a
   *  special-cased terminate here but by the cancel cascade: once the proxied failure resolves upward, this
   *  call is terminated and its `onTerminate` → `terminateChildren` reaches the callee. A cancelling call
   *  drops the ask (its children are being torn down anyway). */
  protected onEscalate(
    event: Extract<ExternalEvent, { kind: "escalate" }>,
    context: { caller: InstanceId | undefined },
  ): void {
    const parent =
      context.caller === undefined ? undefined : this.callByInstance.get(context.caller);
    if (parent === undefined) return; // the raiser's call is gone; the child is being torn down independently
    const call = this.calls.get(parent);
    // Drop the ask when the call is winding its children down — `cancelling` (a terminate from above), or a
    // completion already `pendingOutcome` (the transport finished and `complete` terminated the children):
    // the child is being torn down, so its escalate is moot, and forwarding it would relay an ask the call
    // will orphan when it resolves and drops. Symmetric to `openInnerDelegation`, which refuses new work in
    // exactly these two states.
    if (call === undefined || call.status === "cancelling" || call.pendingOutcome !== undefined) {
      return;
    }
    const { instance, caller, run } = this.routeOf(parent);
    const outer = newEscalationId();
    call.relays.set(outer, { child: event.delegation, escalation: event.escalation });
    this.dirty.add(parent);
    this.send(
      {
        kind: "escalate",
        delegation: parent,
        escalation: outer,
        ask: event.ask,
        from: this.name,
        to: caller,
        run,
      },
      instance,
    );
  }

  // ─── the shared callee lifecycle ─────────────────────────────────────────────────────────────────

  /** A `delegate` opened a call: record the received-delegation edge (instance + summoner) in the base, then
   *  hold only the transport status + payload locally. The transport dispatch is a post-commit side effect. */
  protected onDelegate(event: Extract<ExternalEvent, { kind: "delegate" }>): void {
    if (event.target.kind !== "external") return; // only external targets route here
    const instance = newInstanceId();
    this.acceptDelegation(event.delegation, instance, event.from, event.run);
    this.callByInstance.set(instance, event.delegation);
    this.put(event.delegation, {
      status: "running",
      payload: this.openPayload(event.target, event.argument, event.generics),
      relays: new Map(),
      transportSettled: false,
      pendingOutcome: undefined,
    });
  }

  /** A `terminate` reached the call: move it to `cancelling` (the transport abort runs post-commit; a call
   *  whose transport already stopped — `awaitingAnswer` — counts as settled at once), distribute the cancel
   *  to its live children, and ack upward only once the transport AND every child confirmed. */
  protected onTerminate(event: Extract<ExternalEvent, { kind: "terminate" }>): void {
    const call = this.calls.get(event.delegation);
    if (call === undefined) {
      // No such call — it resolved concurrently (its ack is in flight). Confirm anyway so the caller's
      // cancel cascade completes; a caller whose proxy has meanwhile resolved ignores a stray ack.
      this.send({
        kind: "terminateAck",
        delegation: event.delegation,
        from: this.name,
        to: event.from,
        run: event.run,
      });
      return;
    }
    if (call.status === "cancelling") return;
    const { instance, run } = this.routeOf(event.delegation);
    // An errored call (`awaitingAnswer`) has no transport work left to confirm; a held completion is moot.
    call.transportSettled = call.status === "awaitingAnswer";
    call.pendingOutcome = undefined;
    call.status = "cancelling";
    this.dirty.add(event.delegation);
    this.terminateChildren(instance, run);
    this.maybeSettle(event.delegation);
  }

  /** The answer to an escalation under this call arrived. A relayed one (a child's ask this reactor proxied
   *  up) descends to that child; otherwise it is the answer to the call's own error panic — a handler caught
   *  it, and the answer becomes the call's result. */
  protected onEscalateAck(
    event: Extract<ExternalEvent, { kind: "escalateAck" }>,
    _context: { raiser: InstanceId | undefined },
  ): void {
    const call = this.calls.get(event.delegation);
    if (call === undefined) return;
    const relay = call.relays.get(event.escalation);
    if (relay !== undefined) {
      call.relays.delete(event.escalation);
      this.dirty.add(event.delegation);
      const to = this.issuedPeerOf(relay.child);
      if (to === undefined) return; // the child retired while the ask was open (cancelled) — the answer is moot
      // An escalateAck owns no row and releases nothing, so it needs no issuer.
      this.send({
        kind: "escalateAck",
        delegation: relay.child,
        escalation: relay.escalation,
        value: event.value,
        from: this.name,
        to,
        run: event.run,
      });
      return;
    }
    if (call.status !== "awaitingAnswer") return;
    const { instance, caller, run } = this.routeOf(event.delegation);
    this.send(
      {
        kind: "delegateAck",
        delegation: event.delegation,
        value: event.value,
        from: this.name,
        to: caller,
        run,
      },
      instance,
    );
    this.drop(event.delegation);
  }

  /** A transport completion for one call (the reactor's ephemeral inbound, fed through the substrate). For a
   *  cancelling call any completion confirms the transport's half of the abort. Otherwise the outcome is
   *  held; children the callee left running are cancelled (their results can no longer be observed), and the
   *  call settles once drained — immediately when it has none. */
  complete(completion: ExternalCompletion): void {
    const call = this.calls.get(completion.delegation);
    if (call === undefined) return; // a late completion for a call already resolved
    const { instance, run } = this.routeOf(completion.delegation);
    if (call.status === "cancelling") {
      call.transportSettled = true;
      this.maybeSettle(completion.delegation);
      return;
    }
    call.pendingOutcome = completion.outcome;
    this.terminateChildren(instance, run);
    this.maybeSettle(completion.delegation);
  }

  /** Cancel every still-running inner delegation of `instance` (one already cancelling has its terminate in
   *  flight — from the turn that moved it, replayed from the outbox after a crash). `run` is the parent
   *  call's trace context (its children run under the same run). */
  private terminateChildren(instance: InstanceId, run: InstanceId): void {
    for (const child of this.issuedDelegationsOf(instance)) {
      if (child.state !== "running") continue;
      this.send({
        kind: "terminate",
        delegation: child.delegation,
        from: this.name,
        to: child.peer,
        run,
      });
    }
  }

  /** Settle `delegation` if nothing is outstanding: all children drained, and — when cancelling — the
   *  transport confirmed. Applies the held outcome (result → delegateAck, error → the panic escalation +
   *  `awaitingAnswer`, cancelled → terminateAck) or completes the cancel barrier. Idempotent per trigger:
   *  each child ack / transport confirmation re-checks. */
  private maybeSettle(delegation: DelegationId): void {
    const call = this.calls.get(delegation);
    if (call === undefined) return;
    const { instance, caller, run } = this.routeOf(delegation);
    if (this.hasIssuedDelegations(instance)) return; // children still winding down
    if (call.status === "cancelling") {
      if (!call.transportSettled) return;
      this.send({ kind: "terminateAck", delegation, from: this.name, to: caller, run });
      this.drop(delegation);
      return;
    }
    const outcome = call.pendingOutcome;
    if (outcome === undefined) return;
    call.pendingOutcome = undefined;
    switch (outcome.kind) {
      case "result": {
        // The payload decodes its own ack straight from the transport's raw wire Json (the ONE ack-shaping
        // seam, `AckDecodingPayload`): the default is the base wire decoder, an mcp direct call decodes
        // against its `T` (a typed value, or the raw `json` tree) — all at this boundary, where the value's
        // resources then ascend (`send`'s release, the caller's reown).
        const decode = ackDecoderOf(call.payload) ?? jsonToValue;
        this.send(
          {
            kind: "delegateAck",
            delegation,
            value: decode(outcome.value),
            from: this.name,
            to: caller,
            run,
          },
          instance,
        );
        // A produced blob the result did NOT ascend by value (the narrow backstop: a direct mcp call
        // decoded to a raw `json` tree, whose `$ref` is an inert string, not a real ref) would otherwise be
        // reclaimed by this drop; adopt it onto the run so it survives to the caller — uniform with the
        // value-carried case (a typed decode's REAL ref), which `send` already released to in-transit.
        this.adoptDetachedProducedBlobs(delegation, instance, run);
        this.drop(delegation);
        return;
      }
      case "cancelled":
        this.send({ kind: "terminateAck", delegation, from: this.name, to: caller, run });
        this.drop(delegation);
        return;
      case "throw":
        // The callee raised a typed error of its own: re-raise it as `prelude.throw`, so a katari-side
        // handler catches the sidecar's error exactly like a stdlib throw. Like the error case the call
        // then waits — a throw answers with `never`, so resolution comes as a `terminate` (a handler broke
        // out of its handle, or the run is failing). The raiser of the row is this call's own instance.
        this.escalateThrow(delegation, outcome.error, caller, run, instance);
        call.status = "awaitingAnswer";
        this.dirty.add(delegation);
        return;
      case "error":
        // A no-result error escalates to the caller (panic by default; a reactor whose errors a program
        // anticipates — http — overrides with a typed throw). Unhandled, it fails the run; if a handler
        // catches it, the escalateAck becomes this call's result (so the call waits, awaitingAnswer). The
        // raiser of the row is this call's own instance.
        this.escalateError(delegation, outcome.message, caller, run, instance);
        call.status = "awaitingAnswer";
        this.dirty.add(delegation);
        return;
    }
  }

  /** The escalation a typed `throw` completion becomes: the payload decodes at this seam (the transport
   *  boundary, like a result's value) and re-raises as `prelude.throw`. A payload that does not decode is
   *  protocol drift, not a program-anticipatable error — that one degrades to a panic.
   *
   *  KNOWN GAP (FFI typing): the payload is decoded with the plain wire decoder and is NOT validated /
   *  coerced against the external agent's DECLARED `throw[T]`. An FFI author who raises a plain record
   *  (forgetting the port's `KatariData` nominal tag) yields a value that statically claims `T` but carries
   *  no constructor tag, so a downstream `case T(...)` match finds no arm — a silent no-match (surfaced, not
   *  introduced, by replay converters doing a nominal `match`; the `replay_probe` fixture works around it by
   *  re-tagging the payload as a nominal `data` in Katari). PROPOSED FIX: add a `decodeThrow?: (raw: Json) =>
   *  Value` seam to the call payload, exactly mirroring `AckDecodingPayload.decodeAck` — populated by the ffi
   *  reactor's `openPayload` from the external agent's declared throw generic — so this site coerces the raw
   *  payload against `T` (reconstructing / tagging it) or raises a loud typed `decode_error` when its
   *  constructor does not match, instead of `jsonToValue`. Deferred here to avoid an FFI-typing overhaul. */
  private escalateThrow(
    delegation: DelegationId,
    error: Json,
    caller: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    let payload: Value;
    try {
      payload = jsonToValue(error);
    } catch (cause) {
      this.raisePanic(
        delegation,
        `the callee threw an undecodable error payload: ${messageOf(cause)}`,
        caller,
        run,
        raiser,
      );
      return;
    }
    this.raiseThrow(delegation, payload, caller, run, raiser);
  }

  /** The escalation a no-result error becomes. Panic by default — an external process / infrastructure
   *  failure is not a program-anticipatable error (typed sidecar throws are a port follow-up); the http
   *  reactor overrides with `throw[http.fetch_error]`, which a program catches to control retry. */
  protected escalateError(
    delegation: DelegationId,
    message: string,
    caller: ReactorName,
    run: InstanceId,
    raiser: InstanceId,
  ): void {
    this.raisePanic(delegation, message, caller, run, raiser);
  }

  /** Bridge a settled inner delegation to its transport token and stage the post-commit delivery. A missing
   *  bridge is an orphan — an inner delegation whose transport process died (the bridge outlived its
   *  consumer); its outcome is dropped, and its resources were already re-owned onto the call. */
  private stageInnerDelivery(
    parent: DelegationId,
    child: DelegationId,
    outcome: InnerDelivery["outcome"],
  ): void {
    const bridge = this.innerCalls.get(child);
    if (bridge === undefined) return;
    this.innerCalls.delete(child);
    this.unindexInnerCall(bridge.parent, child);
    this.dirty.add(parent);
    this.pendingDeliveries.push({ delegation: parent, call: bridge.call, outcome });
  }

  /** Dispatch / abort the transport and deliver settled inner calls strictly after the turn commits
   *  (durable-first): a freshly opened call is dispatched, a now-cancelling one is aborted, and the
   *  deliveries this turn staged go out. A call resolved this turn (dropped) does neither. */
  afterCommit(event: ExternalEvent): void {
    if (event.kind === "delegate" && event.target.kind === "external") {
      const call = this.calls.get(event.delegation);
      if (call !== undefined) this.dispatch(event.delegation, call.payload);
    } else if (event.kind === "terminate") {
      if (this.calls.get(event.delegation)?.status === "cancelling") this.abort(event.delegation);
    }
    const deliveries = this.pendingDeliveries;
    this.pendingDeliveries = [];
    for (const delivery of deliveries) this.deliverInnerOutcome(delivery);
  }

  /** Write the calls this turn touched as own-kind instances (envelope + extension row), dropping resolved
   *  ones (their envelope drop cascades the extension and any capability route). The base additionally
   *  flushes the caller-owned rows of the calls' inner delegations. The envelope status collapses
   *  `awaitingAnswer` to the `running` instance lifecycle (alive, waiting); the extension row carries the
   *  precise status plus the codec-encoded document — and a token-minting kind's capability route commits
   *  alongside it. */
  async persist(tx: PersistenceTx): Promise<void> {
    const live = [...this.dirty].flatMap((delegation) => {
      const call = this.calls.get(delegation);
      // Instance + caller come from the base received edge (present alongside a live call).
      return call === undefined ? [] : [{ delegation, call, route: this.routeOf(delegation) }];
    });
    for (const { delegation, call, route } of live)
      this.markInstance(route.instance, {
        delegationId: delegation,
        // The caller (reply-to) and the run (trace context) are the instance's ambient, written on the
        // generic envelope here — not repeated in the extension document.
        callerReactor: route.caller,
        runId: route.run,
        status: call.status === "cancelling" ? "cancelling" : "running",
      });
    for (const instanceId of this.droppedInstances) this.markInstanceDropped(instanceId);
    await this.persistBase(tx.base);
    for (const { delegation, call, route } of live) {
      await tx.external.putCall({
        instanceId: route.instance,
        status: call.status,
        extension: this.encodeCallExtension({
          instance: route.instance,
          delegation,
          status: call.status,
          payload: call.payload,
          relays: [...call.relays].map(([escalation, relay]) => ({
            escalation,
            child: relay.child,
            childEscalation: relay.escalation,
          })),
          innerCalls: this.innerCallRowsOf(delegation),
        }),
      });
      const token = this.capabilityTokenOf(call.payload);
      if (token !== null) await tx.routes.putRoute({ token, instance: route.instance });
    }
    this.dirty.clear();
    this.droppedInstances = [];
  }

  /** Reload the in-flight calls on reactivation and resume the transport uniformly: a `running` call is
   *  offered back as a `recovery` dispatch (still-live work continues untouched after a warm reset; gone
   *  work fails at-most-once as a panic — and that error path cancels the call's inner delegations, so no
   *  orphans survive a restart), a `cancelling` call re-aborts (the transport confirms with a synthesised
   *  `cancelled`; its children's terminates replay from the outbox), an `awaitingAnswer` call just waits
   *  (its request already stopped; the core side drives the escalation's resolution). The payload + the
   *  inner-delegation bridges reload through the reactor's extension codec. */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const row of await loader.external.instances(this.name)) {
      const decoded = this.decodeCallExtension(row.extension);
      // Re-seed the base received edge (instance + summoner + run) and the local transport status + payload.
      this.acceptDelegation(row.delegation, row.instance, row.caller, row.run);
      this.callByInstance.set(row.instance, row.delegation);
      this.calls.set(row.delegation, {
        status: row.status,
        payload: decoded.payload,
        relays: new Map(
          decoded.relays.map((relay) => [
            relay.escalation,
            { child: relay.child, escalation: relay.childEscalation },
          ]),
        ),
        transportSettled: false,
        pendingOutcome: undefined,
      });
      for (const inner of decoded.innerCalls) {
        this.innerCalls.set(inner.delegation, { parent: row.delegation, call: inner.call });
        this.indexInnerCall(row.delegation, inner.delegation);
      }
      if (row.status === "running") this.recover(row.delegation);
      else if (row.status === "cancelling") this.abort(row.delegation);
    }
  }

  reset(): void {
    super.reset();
    this.calls.clear();
    this.callByInstance.clear();
    this.innerCalls.clear();
    this.innerCallsByParent.clear();
    this.pendingDeliveries = [];
    this.dirty.clear();
    this.droppedInstances = [];
    this.producedBlobs.clear();
  }

  private innerCallRowsOf(parent: DelegationId): InnerCallRow[] {
    const rows: InnerCallRow[] = [];
    const children = this.innerCallsByParent.get(parent);
    if (children === undefined) return rows;
    for (const child of children) {
      const bridge = this.innerCalls.get(child);
      if (bridge !== undefined) rows.push({ delegation: child, call: bridge.call });
    }
    return rows;
  }

  /** Add an inner delegation to its parent call's bucket (creating it on the first inner call). */
  private indexInnerCall(parent: DelegationId, child: DelegationId): void {
    const set = this.innerCallsByParent.get(parent);
    if (set === undefined) this.innerCallsByParent.set(parent, new Set([child]));
    else set.add(child);
  }

  /** Remove an inner delegation from its parent call's bucket, evicting the bucket once empty. */
  private unindexInnerCall(parent: DelegationId, child: DelegationId): void {
    const set = this.innerCallsByParent.get(parent);
    if (set === undefined) return;
    set.delete(child);
    if (set.size === 0) this.innerCallsByParent.delete(parent);
  }

  /** Adopt onto the run every blob this call produced that its result did not ascend by value. `send`'s
   *  delegateAck release has already moved the value-carried resources to in-transit (owner = null) for the
   *  caller to reown; a produced blob still owned by the ephemeral `call` instance is one the result carried
   *  only as an inert handle (a direct mcp call decoded to a raw `json` tree — `T = json.json` — where the
   *  `$ref` is a string, not a real ref) — so it moves onto the long-lived `run`, readable until the run's
   *  teardown reclaims it. Uniform across call shapes: a callTool / ffi result, and a TYPED direct call
   *  whose `$ref` reconstructs a real ref, carry all their produced blobs by value, so this is a no-op there. */
  private adoptDetachedProducedBlobs(
    delegation: DelegationId,
    call: InstanceId,
    run: InstanceId,
  ): void {
    const produced = this.producedBlobs.get(delegation);
    if (produced !== undefined) this.pool.reassignOwnedBlobs(call, run, produced);
  }

  private put(delegation: DelegationId, call: Call<Payload>): void {
    this.calls.set(delegation, call);
    this.dirty.add(delegation);
  }

  private drop(delegation: DelegationId): void {
    this.onDropCall(delegation);
    this.producedBlobs.delete(delegation);
    const instance = this.handledInstanceOf(delegation);
    if (instance !== undefined) {
      this.droppedInstances.push(instance);
      this.callByInstance.delete(instance);
    }
    // Stale inner-call bridges (an orphan child still running as its parent resolves) die with the call.
    const children = this.innerCallsByParent.get(delegation);
    if (children !== undefined) {
      for (const child of children) this.innerCalls.delete(child);
      this.innerCallsByParent.delete(delegation);
    }
    this.calls.delete(delegation);
    this.dropHandled(delegation);
    this.dirty.delete(delegation);
  }
}

/** Lower a settled inner delegation's outcome to the transport-completion shape `complete` consumes —
 *  for a reactor whose WHOLE call settles with one designated inner delegation (webhook / mcp-serve: the
 *  subscriber's outcome is the call's outcome, fed back as a synthesised completion). `reveal` keeps
 *  content across the internal Json round-trip (this boundary faces the engine, not a user). */
export function innerOutcomeAsCompletion(
  outcome: InnerDelivery["outcome"],
): ExternalCompletion["outcome"] {
  switch (outcome.kind) {
    case "result":
      return { kind: "result", value: valueToJson(outcome.value, "reveal") };
    case "error":
      return { kind: "error", message: outcome.message };
    case "cancelled":
      return { kind: "cancelled" };
  }
}
