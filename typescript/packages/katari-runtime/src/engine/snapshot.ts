// Snapshot: pure JSON conversion for State.
//
// Because State is plain data (Record-of-data, no class instances, no
// non-JSON values), serialize is just a structuredClone-equivalent and
// deserialize is the inverse. Selfendpoint / ffiTargetEndpoint are
// included so they survive the round-trip.
//
// We deliberately do NOT serialize the IRModule into the snapshot — the
// host supplies it on restore (it's the source of truth, separately
// versioned). Keeping snapshots IR-free keeps them small and easy to
// migrate when only the IR changes.

import type { IRModule } from "../ir/types.js";
import type { State } from "./state.js";

export type Snapshot = {
  schemaVersion: 3;
  selfEndpoint: string;
  ffiTargetEndpoint: string;
  threads: State["threads"];
  scopes: State["scopes"];
  closures: State["closures"];
  nextClosureId: number;
  delegations: State["delegations"];
  pendingDelegateOut: State["pendingDelegateOut"];
  delegationSenders: State["delegationSenders"];
  lastGcScopeCount: number;
};

export function serialize(state: State): Snapshot {
  return {
    schemaVersion: 3,
    selfEndpoint: state.selfEndpoint,
    ffiTargetEndpoint: state.ffiTargetEndpoint,
    threads: structuredClone(state.threads),
    scopes: structuredClone(state.scopes),
    closures: structuredClone(state.closures),
    nextClosureId: state.nextClosureId,
    delegations: structuredClone(state.delegations),
    pendingDelegateOut: structuredClone(state.pendingDelegateOut),
    delegationSenders: structuredClone(state.delegationSenders),
    lastGcScopeCount: state.lastGcScopeCount,
  };
}

export function deserialize(irModule: IRModule, snap: Snapshot): State {
  if (snap.schemaVersion !== 3) {
    throw new Error(`engine.snapshot: unsupported schemaVersion ${snap.schemaVersion}`);
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
    ffiTargetEndpoint: snap.ffiTargetEndpoint as State["ffiTargetEndpoint"],
    lastGcScopeCount: snap.lastGcScopeCount,
  };
}
