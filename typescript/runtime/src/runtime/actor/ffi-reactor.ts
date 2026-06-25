// FfiReactor: the `ffi` reactor — the external (FFI) world as a reactor sibling to core / api. An external
// call reaches it as a `delegate` (target `{ external, key }`) routed from core's `ExternalThread` proxy,
// exactly like a core sub-call's delegate; it dispatches the handler through its transport and turns the
// transport's completion into the call's `delegateAck` (result), an `escalate` (an FFI error → a panic), or
// a `terminateAck` (an abort confirmed). It owns its in-flight calls as durable `ffi_calls` records (its
// callee-side warm state), re-dispatched on recovery — symmetric to core owning its instances.
//
// A call's lifecycle mirrors a core sub-call's: running (transport in flight) → result / error / cancel.
// On an FFI *error* the call does not finish: like a panicking sub-call instance that stays suspended on the
// panic ask, it escalates the panic and waits (`awaitingAnswer`) for either an `escalateAck` (a handler
// caught it — the answer becomes the result) or a `terminate` (unhandled — the run is failing). The actual
// process call has stopped, so that wait needs no transport.

import { PANIC_REQUEST } from "../engine/common.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import type { FfiCompletion, FfiTransport } from "../external/runner.js";
import {
  type DelegationId,
  type InstanceId,
  newEscalationId,
  newInstanceId,
  type ProjectId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import { Reactor } from "./reactor.js";
import type { ResourcePool } from "./resource-pool.js";

/** One in-flight external call — the ffi reactor's per-delegation callee instance (the ffi analogue of a
 *  core child instance: ffi is delegated *to*, so each delegation gets its own instance, not a shared root).
 *  `instance` is its own id (the issuer stamped on the replies it produces); `caller` is the reactor that
 *  issued the delegate (its reply goes back there — `core` in v0.1.0). `status`: `running` (transport in
 *  flight), `cancelling` (aborting, awaiting the transport's stop), or `awaitingAnswer` (transport errored,
 *  panic escalated, awaiting a caught-panic answer or the run's terminate). */
interface PendingCall {
  instance: InstanceId;
  key: string;
  argument: Value | null;
  caller: ReactorName;
  status: "running" | "cancelling" | "awaitingAnswer";
}

export class FfiReactor extends Reactor {
  readonly name: ReactorName = "ffi";

  /** In-flight calls (warm SoT) keyed by their delegation, plus the per-turn dirty set `persist` flushes. */
  private readonly calls = new Map<DelegationId, PendingCall>();
  private readonly dirty = new Set<DelegationId>();
  /** The call whose turn this is — its instance is the issuer stamped on the replies it produces. Set by the
   *  handler that produces a reply (a completion, or an answering / terminating react). */
  private turnInstance: InstanceId | undefined;

  constructor(
    private readonly projectId: ProjectId,
    private readonly transport: FfiTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  currentTurnOwner(): InstanceId {
    if (this.turnInstance === undefined) {
      throw new Error("FfiReactor.currentTurnOwner read with no call instance (engine bug)");
    }
    return this.turnInstance;
  }

  /** React to one event a delegation routes to ffi: a `delegate` opens a call, a `terminate` aborts one, an
   *  `escalateAck` is a caught panic's answer (→ the call's result). It never receives a `delegateAck` /
   *  `escalate` / `terminateAck` (those are the replies it sends). The transport dispatch / abort is a
   *  strictly-post-commit side effect (`afterCommit`). */
  react(event: ExternalEvent): void {
    switch (event.kind) {
      case "delegate": {
        if (event.target.kind !== "external") return; // only external targets route here
        // A fresh per-delegation callee instance, like core's createInstance for a sub-call.
        this.put(event.delegation, {
          instance: newInstanceId(),
          key: event.target.key,
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
          // The process call already stopped (it errored); confirm the abort straight away.
          this.turnInstance = call.instance;
          this.send({ kind: "terminateAck", delegation: event.delegation }, call.caller);
          this.drop(event.delegation);
        } else if (call.status === "running") {
          call.status = "cancelling";
          this.dirty.add(event.delegation);
        }
        break;
      }
      case "escalateAck": {
        // A handler caught the FFI error's panic and answered: the answer becomes the call's result.
        const call = this.calls.get(event.delegation);
        if (call === undefined || call.status !== "awaitingAnswer") return;
        this.turnInstance = call.instance;
        this.send(
          { kind: "delegateAck", delegation: event.delegation, value: event.value },
          call.caller,
        );
        this.drop(event.delegation);
        break;
      }
    }
  }

  /** A transport completion for one call (the ffi reactor's ephemeral inbound, fed through the substrate).
   *  For a cancelling call any completion confirms the abort; otherwise a result acks it, and an error
   *  escalates a panic and waits for the answer / the run's terminate. */
  complete(completion: FfiCompletion): void {
    const call = this.calls.get(completion.delegation);
    if (call === undefined) return; // a late completion for a call already resolved
    this.turnInstance = call.instance;
    if (call.status === "cancelling") {
      this.send({ kind: "terminateAck", delegation: completion.delegation }, call.caller);
      this.drop(completion.delegation);
      return;
    }
    switch (completion.outcome.kind) {
      case "result":
        this.send(
          {
            kind: "delegateAck",
            delegation: completion.delegation,
            value: completion.outcome.value,
          },
          call.caller,
        );
        this.drop(completion.delegation);
        return;
      case "cancelled":
        this.send({ kind: "terminateAck", delegation: completion.delegation }, call.caller);
        this.drop(completion.delegation);
        return;
      case "error":
        this.send(
          {
            kind: "escalate",
            delegation: completion.delegation,
            escalation: newEscalationId(),
            ask: {
              kind: "request",
              request: PANIC_REQUEST,
              argument: panicArgument(completion.outcome.message),
            },
          },
          call.caller,
        );
        call.status = "awaitingAnswer";
        this.dirty.add(completion.delegation);
        return;
    }
  }

  /** Dispatch / abort the transport strictly after the turn commits (durable-first): a freshly opened call is
   *  dispatched, a now-cancelling one is aborted. A call that resolved this turn (dropped) does neither. */
  afterCommit(event: ExternalEvent): void {
    if (event.kind === "delegate" && event.target.kind === "external") {
      this.transport.dispatch({
        projectId: this.projectId,
        delegation: event.delegation,
        key: event.target.key,
        argument: event.argument,
      });
    } else if (event.kind === "terminate") {
      if (this.calls.get(event.delegation)?.status === "cancelling") {
        this.transport.abort(event.delegation);
      }
    }
  }

  /** Write the calls this turn touched, dropping resolved ones. (The ffi reactor owns no delegations /
   *  escalations, so there is no base Layer 1 to flush.) */
  async persist(tx: PersistenceTx): Promise<void> {
    for (const delegation of this.dirty) {
      const call = this.calls.get(delegation);
      if (call === undefined) await tx.dropFfiCall(delegation);
      else
        await tx.putFfiCall({
          delegation,
          instance: call.instance,
          key: call.key,
          argument: call.argument,
          caller: call.caller,
          status: call.status,
        });
    }
    this.dirty.clear();
  }

  /** Reload the in-flight calls and resume the transport: a `running` call re-dispatches (its handler may
   *  re-run — `redispatch` lets it dedupe), a `cancelling` call re-aborts, an `awaitingAnswer` call just
   *  waits (its process call already stopped; the core side drives the escalation's resolution). */
  async load(loader: Loader): Promise<void> {
    for (const row of await loader.ffiCalls()) {
      this.calls.set(row.delegation, {
        instance: row.instance,
        key: row.key,
        argument: row.argument,
        caller: row.caller,
        status: row.status,
      });
      if (row.status === "running") {
        this.transport.dispatch({
          projectId: this.projectId,
          delegation: row.delegation,
          key: row.key,
          argument: row.argument,
          redispatch: true,
        });
      } else if (row.status === "cancelling") {
        this.transport.abort(row.delegation);
      }
    }
  }

  reset(): void {
    super.reset();
    this.calls.clear();
    this.dirty.clear();
    this.turnInstance = undefined;
  }

  private put(delegation: DelegationId, call: PendingCall): void {
    this.calls.set(delegation, call);
    this.dirty.add(delegation);
  }

  private drop(delegation: DelegationId): void {
    this.calls.delete(delegation);
    this.dirty.add(delegation);
  }
}

/** The `{ msg }` record a panic carries (matching `raisePanic`). */
function panicArgument(message: string): Value {
  return { kind: "record", fields: { msg: { kind: "string", value: message } } };
}
