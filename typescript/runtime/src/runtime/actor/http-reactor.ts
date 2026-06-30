// HttpReactor: the `http` reactor — a built-in HTTP client as a reactor sibling to core / api / ffi. An
// `http.fetch` call reaches it as a `delegate` (target `{ external, reactor: "http" }`) routed from core's
// `ExternalThread` proxy, exactly like an FFI call; it performs the request through its transport (an
// in-runtime `fetch`) and turns the outcome into the call's `delegateAck` (the `{ status, body }` response),
// an `escalate` (a request that produced no response → a panic that bubbles to the caller's handler), or a
// `terminateAck` (an abort confirmed).
//
// It owns its in-flight calls durably as `http`-kind instances (`http_instances` — the call's status), and on
// recovery it does NOT re-send (an http request is not idempotent): the transport's re-dispatch reports an
// error, so an interrupted call fails with a `panic` the caller can catch and retry. This at-most-once
// guarantee is the whole reason http is a reactor rather than a core-inline primitive.
//
// A call's lifecycle mirrors an FFI call's: running (request in flight) → result / error / cancel. On an
// error the call escalates a panic and waits (`awaitingAnswer`) for either an `escalateAck` (a handler caught
// it — the answer becomes the result) or a `terminate` (unhandled — the run is failing). The request has
// stopped, so that wait needs no transport.

import type { Json } from "@katari-lang/types";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import type { HttpCompletion, HttpTransport } from "../external/http-transport.js";
import { type DelegationId, type InstanceId, newInstanceId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

/** One in-flight http call — the reactor's per-delegation callee instance (like an FFI call). `instance` is
 *  its own id (the issuer stamped on its replies); `caller` is the reactor that issued the delegate (where its
 *  reply routes — `core` today). `argument` is kept only to dispatch the request; it is never persisted
 *  (recovery does not re-send). `status`: `running` (request in flight), `cancelling` (aborting), or
 *  `awaitingAnswer` (errored, panic escalated, awaiting a caught-panic answer or the run's terminate). */
interface PendingCall {
  instance: InstanceId;
  argument: Value | null;
  caller: ReactorName;
  status: "running" | "cancelling" | "awaitingAnswer";
}

export class HttpReactor extends Reactor {
  readonly name: ReactorName = "http";

  /** In-flight calls (warm SoT) keyed by their delegation, plus the per-turn dirty set `persist` upserts and
   *  the instance ids of calls resolved this turn (their envelopes are dropped). */
  private readonly calls = new Map<DelegationId, PendingCall>();
  private readonly dirty = new Set<DelegationId>();
  private droppedInstances: InstanceId[] = [];
  /** The call whose turn this is — its instance is the issuer stamped on the replies it produces. */
  private turnInstance: InstanceId | undefined;

  constructor(
    private readonly transport: HttpTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  currentTurnOwner(): InstanceId {
    if (this.turnInstance === undefined) {
      throw new Error("HttpReactor.currentTurnOwner read with no call instance (engine bug)");
    }
    return this.turnInstance;
  }

  /** React to one event a delegation routes to http: a `delegate` opens a call, a `terminate` aborts one, an
   *  `escalateAck` is a caught panic's answer (→ the call's result). It never receives a `delegateAck` /
   *  `escalate` / `terminateAck` (those are the replies it sends). The transport dispatch / abort is a
   *  strictly-post-commit side effect (`afterCommit`). */
  react(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegate": {
        if (event.target.kind !== "external") return; // only external targets route here
        this.put(event.delegation, {
          instance: newInstanceId(),
          argument: event.argument,
          caller: event.from,
          status: "running",
        });
        break;
      }
      case "terminate": {
        const call = this.calls.get(event.delegation);
        if (call === undefined) return;
        if (call.status === "awaitingAnswer") {
          // The request already stopped (it errored); confirm the abort straight away.
          this.turnInstance = call.instance;
          this.send({
            kind: "terminateAck",
            delegation: event.delegation,
            from: this.name,
            to: call.caller,
          });
          this.drop(event.delegation);
        } else if (call.status === "running") {
          call.status = "cancelling";
          this.dirty.add(event.delegation);
        }
        break;
      }
      case "escalateAck": {
        // A handler caught the error's panic and answered: the answer becomes the call's result.
        const call = this.calls.get(event.delegation);
        if (call === undefined || call.status !== "awaitingAnswer") return;
        this.turnInstance = call.instance;
        this.send({
          kind: "delegateAck",
          delegation: event.delegation,
          value: event.value,
          from: this.name,
          to: call.caller,
        });
        this.drop(event.delegation);
        break;
      }
    }
  }

  /** A transport completion for one call (the reactor's ephemeral inbound, fed through the substrate). For a
   *  cancelling call any completion confirms the abort; otherwise a result acks it (the `{ status, body }`
   *  response), and an error escalates a panic and waits for the answer / the run's terminate. */
  complete(completion: HttpCompletion): void {
    const call = this.calls.get(completion.delegation);
    if (call === undefined) return; // a late completion for a call already resolved
    this.turnInstance = call.instance;
    if (call.status === "cancelling") {
      this.send({
        kind: "terminateAck",
        delegation: completion.delegation,
        from: this.name,
        to: call.caller,
      });
      this.drop(completion.delegation);
      return;
    }
    switch (completion.outcome.kind) {
      case "result":
        // Any HTTP response (2xx or not) is a result: lift it to the public `{ status, body }` value. The
        // response body is declassified (public) even when the request carried a secret header — the same
        // rule the impure (io) call type enforces.
        this.send({
          kind: "delegateAck",
          delegation: completion.delegation,
          value: httpResponseValue(completion.outcome.value),
          from: this.name,
          to: call.caller,
        });
        this.drop(completion.delegation);
        return;
      case "cancelled":
        this.send({
          kind: "terminateAck",
          delegation: completion.delegation,
          from: this.name,
          to: call.caller,
        });
        this.drop(completion.delegation);
        return;
      case "error":
        // A request that produced no response is a panic: escalate it to the caller, where it bubbles to the
        // nearest handler (local error handling). Unhandled, it fails the run; if a handler catches it, the
        // escalateAck becomes this call's result (so the call waits, awaitingAnswer).
        this.raisePanic(completion.delegation, completion.outcome.message, call.caller);
        call.status = "awaitingAnswer";
        this.dirty.add(completion.delegation);
        return;
    }
  }

  /** Dispatch / abort the transport strictly after the turn commits (durable-first): a freshly opened call is
   *  dispatched, a now-cancelling one is aborted. A call resolved this turn (dropped) does neither. */
  afterCommit(event: ExternalEvent): void {
    if (event.kind === "delegate" && event.target.kind === "external") {
      this.transport.dispatch({
        delegation: event.delegation,
        // Lower the engine's Value to plain Json for the request; secret header values are revealed here (http
        // is an allowed sink — an API key flows to its request), unlike the user-facing API which redacts.
        argument: event.argument === null ? null : valueToJson(event.argument, "reveal"),
      });
    } else if (event.kind === "terminate") {
      if (this.calls.get(event.delegation)?.status === "cancelling") {
        this.transport.abort(event.delegation);
      }
    }
  }

  /** Write the calls this turn touched as `http`-kind instances (envelope + the `http_instances` extension
   *  that carries the precise `status` the envelope cannot — `awaitingAnswer` collapses to `running` there),
   *  dropping the resolved ones (their envelope drop cascades the extension). The http reactor owns no
   *  delegations / escalations, so the base flushes none. */
  async persist(tx: PersistenceTx): Promise<void> {
    const live = [...this.dirty].flatMap((delegation) => {
      const call = this.calls.get(delegation);
      return call === undefined ? [] : [{ delegation, call }];
    });
    for (const { delegation, call } of live)
      this.markInstance(call.instance, {
        delegationId: delegation,
        status: call.status === "cancelling" ? "cancelling" : "running",
      });
    for (const instanceId of this.droppedInstances) this.markInstanceDropped(instanceId);
    await this.persistBase(tx.base);
    for (const { call } of live)
      await tx.http.putHttpInstance({ instanceId: call.instance, status: call.status });
    this.dirty.clear();
    this.droppedInstances = [];
  }

  /** Reload the in-flight calls on reactivation and resolve them at-most-once: a `running` / `cancelling`
   *  call re-dispatches, which the transport turns into an error (it never re-sends) — so a running call
   *  fails with a panic and a cancelling call confirms its abort. An `awaitingAnswer` call just waits (its
   *  request already stopped; the core side drives the escalation's resolution). The caller is always `core`
   *  (an `http.fetch` is called from a core agent), so it is not persisted. */
  async load(loader: Loader): Promise<void> {
    await this.loadBase(loader.base);
    for (const row of await loader.http.instances()) {
      this.calls.set(row.delegation, {
        instance: row.instance,
        argument: null,
        caller: "core",
        status: row.status,
      });
      if (row.status === "running" || row.status === "cancelling") {
        this.transport.dispatch({ delegation: row.delegation, argument: null, redispatch: true });
      }
    }
  }

  reset(): void {
    super.reset();
    this.calls.clear();
    this.dirty.clear();
    this.droppedInstances = [];
    this.turnInstance = undefined;
  }

  private put(delegation: DelegationId, call: PendingCall): void {
    this.calls.set(delegation, call);
    this.dirty.add(delegation);
  }

  private drop(delegation: DelegationId): void {
    const call = this.calls.get(delegation);
    if (call !== undefined) this.droppedInstances.push(call.instance);
    this.calls.delete(delegation);
    this.dirty.delete(delegation);
  }
}

/** Build the public `{ status: integer, body: string }` response value from the transport's Json result. */
function httpResponseValue(json: Json): Value {
  let status = 0;
  let body = "";
  if (json !== null && typeof json === "object" && !Array.isArray(json)) {
    const rawStatus = json.status;
    if (typeof rawStatus === "number") status = rawStatus;
    const rawBody = json.body;
    if (typeof rawBody === "string") body = rawBody;
  }
  return {
    kind: "record",
    fields: {
      status: { kind: "integer", value: status },
      body: { kind: "string", value: body },
    },
  };
}
