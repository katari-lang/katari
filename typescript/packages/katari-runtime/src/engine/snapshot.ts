// EngineCheckpoint: pure JSON conversion for engine `State`.
//
// On naming: "Snapshot" refers to the user-facing deploy unit (= IR +
// sidecar JS + schema bundle), represented as `Snapshot` on the
// `katari-api-server` side. This engine-internal freeze is called
// **EngineCheckpoint** to avoid collision.
//
// State is plain data (Record-of-data, no class instances, no non-JSON
// values), so serialize is equivalent to structuredClone, and deserialize
// is the inverse. IRModule is not included here (the host provides it
// from the deploy unit).

import type { IRModule } from "../ir/types.js";
import type { State } from "./state.js";

export type EngineCheckpoint = {
  /**
   * Engine checkpoint layout version. v0.1.0 ships as v1 — the
   * pre-release version numbers (3, 4) used during development were
   * reset since there are no production checkpoints to migrate.
   * Bump on any breaking layout change AFTER v0.1.0.
   */
  schemaVersion: 1;
  selfEndpoint: string;
  ffiTargetEndpoint: string;
  threads: State["threads"];
  scopes: State["scopes"];
  closures: State["closures"];
  nextClosureId: number;
  delegations: State["delegations"];
  pendingDelegateOut: State["pendingDelegateOut"];
  delegationSenders: State["delegationSenders"];
  escalationOwners: State["escalationOwners"];
  lastGcScopeCount: number;
};

export function serialize(state: State): EngineCheckpoint {
  return {
    schemaVersion: 1,
    selfEndpoint: state.selfEndpoint,
    ffiTargetEndpoint: state.ffiTargetEndpoint,
    threads: structuredClone(state.threads),
    scopes: structuredClone(state.scopes),
    closures: structuredClone(state.closures),
    nextClosureId: state.nextClosureId,
    delegations: structuredClone(state.delegations),
    pendingDelegateOut: structuredClone(state.pendingDelegateOut),
    delegationSenders: structuredClone(state.delegationSenders),
    escalationOwners: structuredClone(state.escalationOwners),
    lastGcScopeCount: state.lastGcScopeCount,
  };
}

export function deserialize(
  irModule: IRModule,
  snap: EngineCheckpoint,
): State {
  if (snap.schemaVersion !== 1) {
    throw new Error(
      `engine.checkpoint: unsupported schemaVersion ${snap.schemaVersion}`,
    );
  }
  return {
    selfEndpoint: snap.selfEndpoint as State["selfEndpoint"],
    irModule,
    threads: structuredClone(snap.threads),
    scopes: structuredClone(snap.scopes),
    closures: structuredClone(snap.closures),
    nextClosureId: snap.nextClosureId,
    delegations: structuredClone(snap.delegations),
    pendingDelegateOut: structuredClone(snap.pendingDelegateOut),
    delegationSenders: structuredClone(snap.delegationSenders),
    escalationOwners: structuredClone(snap.escalationOwners),
    ffiTargetEndpoint: snap.ffiTargetEndpoint as State["ffiTargetEndpoint"],
    lastGcScopeCount: snap.lastGcScopeCount,
  };
}
