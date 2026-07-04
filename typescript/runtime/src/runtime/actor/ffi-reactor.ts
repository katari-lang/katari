// FfiReactor: the `ffi` reactor — the external (FFI) world as a call reactor (see 'ExternalCallReactor' for
// the shared callee-call lifecycle). An external call reaches it as a `delegate` routed from core's
// `ExternalThread` proxy; it dispatches the handler through its subprocess transport and the base turns the
// completion into the call's `delegateAck` / `escalate` / `terminateAck`. It owns its in-flight calls as
// durable `ffi_instances` rows (its callee-side warm state) — symmetric to core owning its instances.
// Execution is AT-MOST-ONCE, like http: recovery never re-runs a handler (a handler whose process died
// fails as a panic; retrying is katari-level policy), so the argument is not persisted either — a reloaded
// call carries none, exactly like an http call.
//
// A running handler can call back INTO the runtime (`innerDelegate` — the transport's inbound agent-call
// channel): this reactor only resolves the request to a delegate target — a qualified agent name for `core`
// (the default), or an external key for another call reactor (`ffi` / `http`) — against the parent call's
// own snapshot (an agent and its FFI handler deploy together), and hands it to the base. Everything else
// (the delegation lifecycle, terminate distribution, escalation proxying, the durable correlation) is the
// base's; the settled outcome comes back through `deliverInnerOutcome`, lowered to plain JSON here.

import { createAgentName } from "@katari-lang/types";
import type { BlobEntry } from "../engine/types.js";
import type { DelegateTarget, ReactorName } from "../event/types.js";
import type { FfiInnerDelegate, FfiTransport } from "../external/runner.js";
import type { DelegateOutcome } from "../external/sidecar-protocol.js";
import type { BlobId, DelegationId, ProjectId, SnapshotId } from "../ids.js";
import { jsonToValue, valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalTarget,
  type InnerDelivery,
  type LoadedCall,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** An ffi call's transport data: the snapshot whose sidecar bundle hosts the handler, the dispatch key, and
 *  the argument. Only the snapshot + key persist (recovery never re-runs, so the argument is never re-sent —
 *  a reloaded call carries `null`, like http). */
interface FfiPayload {
  snapshot: SnapshotId;
  key: string;
  argument: Value | null;
}

export class FfiReactor extends ExternalCallReactor<FfiPayload> {
  readonly name: ReactorName = "ffi";

  constructor(
    private readonly projectId: ProjectId,
    private readonly transport: FfiTransport,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  protected openPayload(target: ExternalTarget, argument: Value | null): FfiPayload {
    return { snapshot: target.snapshot, key: target.key, argument };
  }

  protected dispatch(delegation: DelegationId, payload: FfiPayload): void {
    this.transport.dispatch({
      projectId: this.projectId,
      delegation,
      snapshot: payload.snapshot,
      key: payload.key,
      // FFI is an allowed sink for secrets (an API key flows to its external call), so a private argument is
      // revealed to the sidecar here — unlike the user-facing API, which redacts.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
    });
  }

  protected recover(delegation: DelegationId): void {
    this.transport.recover(delegation);
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<FfiPayload>): Promise<void> {
    // The argument is not persisted: recovery never re-runs the handler (at-most-once), so nothing ever
    // reads it back — and not storing it keeps one less secret-bearing value at rest.
    await tx.ffi.putFfiInstance({
      instanceId: row.instance,
      snapshotId: row.payload.snapshot,
      key: row.payload.key,
      status: row.status,
      relays: row.relays,
      innerCalls: row.innerCalls,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<FfiPayload>>> {
    return (await loader.ffi.instances()).map((row) => ({
      delegation: row.delegation,
      instance: row.instance,
      caller: row.caller,
      status: row.status,
      // The argument is not persisted (at-most-once recovery never re-sends), so a reloaded call has none.
      payload: { snapshot: row.snapshot, key: row.key, argument: null },
      relays: row.relays,
      innerCalls: row.innerCalls,
    }));
  }

  // ─── the inner agent-call channel (a handler calling back into the runtime) ─────────────────────

  /** A running handler asked to call another agent. Resolve the request to a delegate target against the
   *  parent call's snapshot and open the inner delegation through the base; a request that cannot be
   *  accepted (an unknown reactor, an undecodable argument, a call that is gone or cancelling) is failed
   *  back to the sidecar immediately — nothing was opened, so there is nothing durable to settle. */
  innerDelegate(request: FfiInnerDelegate): void {
    const payload = this.payloadOf(request.delegation);
    if (payload === undefined) {
      this.failInnerDelegate(request, { kind: "cancelled" });
      return;
    }
    const resolved = resolveInnerTarget(request, payload.snapshot);
    if ("error" in resolved) {
      this.failInnerDelegate(request, { kind: "error", message: resolved.error });
      return;
    }
    let argument: Value | null;
    try {
      argument = request.argument === null ? null : jsonToValue(request.argument);
    } catch (error) {
      this.failInnerDelegate(request, {
        kind: "error",
        message: `the call argument is not a decodable value: ${messageOf(error)}`,
      });
      return;
    }
    const delegation = this.openInnerDelegation(
      request.delegation,
      resolved.target,
      resolved.to,
      argument,
      request.call,
    );
    if (delegation === null) this.failInnerDelegate(request, { kind: "cancelled" });
  }

  /** Fail an inner call straight back to the sidecar, outside the durable protocol (no delegation was
   *  opened). Delivered directly — this runs in an originated turn, and the rejection depends on no
   *  durable state, so post-commit staging would gain nothing. */
  private failInnerDelegate(
    request: FfiInnerDelegate,
    outcome: { kind: "error"; message: string } | { kind: "cancelled" },
  ): void {
    this.transport.deliverDelegateResult({
      delegation: request.delegation,
      call: request.call,
      outcome,
    });
  }

  protected deliverInnerOutcome(delivery: InnerDelivery): void {
    this.transport.deliverDelegateResult({
      delegation: delivery.delegation,
      call: delivery.call,
      outcome: lowerInnerOutcome(delivery.outcome),
    });
  }

  /** Register a blob a running handler produced mid-call (its bytes already in the `BlobStore`) as owned by
   *  this call's instance — so the call's `delegateAck` ascends it to the core caller through the base reactor's
   *  release / reown, exactly like a core sub-call's result blob. Run as an out-of-loop command turn (the blob
   *  upload's HTTP request), so the ownership row commits durably before the handler's result is processed.
   *  Returns whether it took: `false` when the call is already gone (cancelled / completed), so the caller can
   *  delete the just-uploaded bytes — which have no row referencing them — rather than orphan them. */
  registerProducedBlob(
    delegation: DelegationId,
    blobId: BlobId,
    entry: Omit<BlobEntry, "owner">,
  ): boolean {
    const instance = this.callInstance(delegation);
    if (instance === undefined) return false;
    this.pool.registerBlob(blobId, { owner: instance, ...entry });
    return true;
  }
}

/** Lower a settled inner outcome to the sidecar's wire form. A result — and a typed throw's payload — cross
 *  the same boundary: the FFI sidecar is the allowed secret sink, exactly like the outer call's argument. */
function lowerInnerOutcome(outcome: InnerDelivery["outcome"]): DelegateOutcome {
  switch (outcome.kind) {
    case "result":
      return { kind: "result", value: valueToJson(outcome.value, "reveal") };
    case "throw":
      return { kind: "throw", error: valueToJson(outcome.value, "reveal") };
    default:
      return outcome;
  }
}

/** Resolve an inner call to a delegate target: the `core` reactor (the default) runs a named agent; a call
 *  reactor (`ffi` / `http`) runs an external key. Both resolve against the parent call's snapshot — an
 *  agent and its FFI handlers deploy together, so the sidecar names siblings of its own version (http
 *  ignores the snapshot). `api` is not a callee, and an unknown name is a spelling error — both fail. */
function resolveInnerTarget(
  request: FfiInnerDelegate,
  snapshot: SnapshotId,
): { target: DelegateTarget; to: ReactorName } | { error: string } {
  if (request.agent.length === 0) return { error: "the agent to call must be a non-empty name" };
  const reactor = request.reactor ?? "core";
  switch (reactor) {
    case "core":
      return {
        target: { kind: "named", name: createAgentName(request.agent), snapshot },
        to: "core",
      };
    case "ffi":
    case "http":
      return { target: { kind: "external", key: request.agent, snapshot }, to: reactor };
    default:
      return { error: `unknown reactor "${reactor}" (expected "core", "ffi", or "http")` };
  }
}
