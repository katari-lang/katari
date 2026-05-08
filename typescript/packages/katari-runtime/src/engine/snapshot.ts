// Snapshot: pure JSON conversion for State.
//
// Because State is plain data (Record-of-data, no class instances, no
// non-JSON values), serialize is just a structuredClone-equivalent and
// deserialize is the inverse. Selfendpoint is included in the snapshot
// so the host can verify it on restore.
//
// We deliberately do NOT serialize the IRModule into the snapshot — the
// host supplies it on restore (it's the source of truth, separately
// versioned). Keeping snapshots IR-free keeps them small and easy to
// migrate when only the IR changes.

import type { IRModule } from "../ir/types.js";
import type { State } from "./state.js";

export type Snapshot = {
  schemaVersion: 1;
  selfEndpoint: string;
  threads: State["threads"];
  scopes: State["scopes"];
  lastGcScopeCount: number;
};

export function serialize(state: State): Snapshot {
  return {
    schemaVersion: 1,
    selfEndpoint: state.selfEndpoint,
    // structuredClone keeps these JSON-safe: Threads/Scopes have no
    // class instances or non-JSON values (closures carry plain
    // ScopeId strings).
    threads: structuredClone(state.threads),
    scopes: structuredClone(state.scopes),
    lastGcScopeCount: state.lastGcScopeCount,
  };
}

export function deserialize(irModule: IRModule, snap: Snapshot): State {
  if (snap.schemaVersion !== 1) {
    throw new Error(`engine.snapshot: unsupported schemaVersion ${snap.schemaVersion}`);
  }
  return {
    selfEndpoint: snap.selfEndpoint as State["selfEndpoint"],
    irModule,
    threads: structuredClone(snap.threads),
    scopes: structuredClone(snap.scopes),
    lastGcScopeCount: snap.lastGcScopeCount,
  };
}
