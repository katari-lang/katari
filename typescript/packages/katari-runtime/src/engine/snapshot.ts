// EngineCheckpoint: pure JSON conversion for engine `State`.
//
// 名前について: 「Snapshot」は user-facing の deploy unit (= IR + sidecar JS +
// schema bundle) を指し、それは `katari-api-server` 側で `Snapshot` 型で
// 表される。この engine 内部の凍結は **EngineCheckpoint** と呼んで衝突を回避。
//
// State は plain data (Record-of-data, no class instances, no non-JSON values)
// なので serialize は structuredClone 相当、deserialize は逆変換。
// IRModule はここに含めない (host が deploy unit から渡す)。

import type { IRModule } from "../ir/types.js";
import type { State } from "./state.js";

export type EngineCheckpoint = {
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

export function serialize(state: State): EngineCheckpoint {
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

export function deserialize(
  irModule: IRModule,
  snap: EngineCheckpoint,
): State {
  if (snap.schemaVersion !== 3) {
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
    ffiTargetEndpoint: snap.ffiTargetEndpoint as State["ffiTargetEndpoint"],
    lastGcScopeCount: snap.lastGcScopeCount,
  };
}
