// FfiReactor: the `ffi` reactor — the external (FFI) world as a call reactor (see 'ExternalCallReactor' for
// the shared callee-call lifecycle). An external call reaches it as a `delegate` routed from core's
// `ExternalThread` proxy; it dispatches the handler through its subprocess transport and the base turns the
// completion into the call's `delegateAck` / `escalate` / `terminateAck`. It owns its in-flight calls as
// durable `ffi_instances` rows (its callee-side warm state), re-dispatched on recovery so an interrupted
// handler re-runs (deduping on the `redispatch` flag) — symmetric to core owning its instances.

import type { BlobEntry } from "../engine/types.js";
import type { ReactorName } from "../event/types.js";
import type { FfiTransport } from "../external/runner.js";
import type { BlobId, DelegationId, ProjectId, SnapshotId } from "../ids.js";
import { valueToJson } from "../value/codec.js";
import type { Value } from "../value/types.js";
import {
  type CallRow,
  ExternalCallReactor,
  type ExternalTarget,
  type LoadedCall,
} from "./external-call-reactor.js";
import type { Loader, PersistenceTx } from "./persistence.js";
import type { ResourcePool } from "./resource-pool.js";

/** The transport data an ffi call recovers from: the snapshot whose sidecar bundle hosts the handler, the
 *  dispatch key, and the argument (re-sent on a recovery re-dispatch). */
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

  protected dispatch(delegation: DelegationId, payload: FfiPayload, redispatch: boolean): void {
    this.transport.dispatch({
      projectId: this.projectId,
      delegation,
      snapshot: payload.snapshot,
      key: payload.key,
      // FFI is an allowed sink for secrets (an API key flows to its external call), so a private argument is
      // revealed to the sidecar here — unlike the user-facing API, which redacts.
      argument: payload.argument === null ? null : valueToJson(payload.argument, "reveal"),
      redispatch,
    });
  }

  protected abort(delegation: DelegationId): void {
    this.transport.abort(delegation);
  }

  protected async persistCallRow(tx: PersistenceTx, row: CallRow<FfiPayload>): Promise<void> {
    await tx.ffi.putFfiInstance({
      instanceId: row.instance,
      snapshotId: row.payload.snapshot,
      key: row.payload.key,
      argument: row.payload.argument,
      callerReactor: row.caller,
      status: row.status,
    });
  }

  protected async loadCallRows(loader: Loader): Promise<Array<LoadedCall<FfiPayload>>> {
    return (await loader.ffi.instances()).map((row) => ({
      delegation: row.delegation,
      instance: row.instance,
      caller: row.caller,
      status: row.status,
      payload: { snapshot: row.snapshot, key: row.key, argument: row.argument },
    }));
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
