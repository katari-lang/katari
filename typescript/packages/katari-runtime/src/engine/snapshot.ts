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
  /**
   * Bump on any breaking layout change.
   *   3: pre-escalationOwners
   *   4: adds escalationOwners (= EscalationId → ThreadId index).
   *      Schema-version-3 checkpoints are still accepted on load;
   *      `deserialize` reconstructs the index from existing thread
   *      `pendingEscalations` maps so older state can be replayed
   *      after an upgrade.
   */
  schemaVersion: 3 | 4;
  selfEndpoint: string;
  ffiTargetEndpoint: string;
  threads: State["threads"];
  scopes: State["scopes"];
  closures: State["closures"];
  nextClosureId: number;
  delegations: State["delegations"];
  pendingDelegateOut: State["pendingDelegateOut"];
  delegationSenders: State["delegationSenders"];
  /** Absent on schemaVersion=3 checkpoints; reconstructed on load. */
  escalationOwners?: State["escalationOwners"];
  lastGcScopeCount: number;
};

export function serialize(state: State): EngineCheckpoint {
  return {
    schemaVersion: 4,
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
  if (snap.schemaVersion !== 3 && snap.schemaVersion !== 4) {
    throw new Error(
      `engine.checkpoint: unsupported schemaVersion ${snap.schemaVersion}`,
    );
  }
  const threads = structuredClone(snap.threads);
  // schemaVersion=3 checkpoints predate `escalationOwners`. Reconstruct
  // the index from the per-thread `pendingEscalations` so escalateAck
  // routing keeps working without forcing a full re-resolve.
  const escalationOwners =
    snap.escalationOwners !== undefined
      ? structuredClone(snap.escalationOwners)
      : rebuildEscalationOwners(threads);
  return {
    selfEndpoint: snap.selfEndpoint as State["selfEndpoint"],
    irModule,
    threads,
    scopes: structuredClone(snap.scopes),
    closures: structuredClone(snap.closures),
    nextClosureId: snap.nextClosureId,
    delegations: structuredClone(snap.delegations),
    pendingDelegateOut: structuredClone(snap.pendingDelegateOut),
    delegationSenders: structuredClone(snap.delegationSenders),
    escalationOwners,
    ffiTargetEndpoint: snap.ffiTargetEndpoint as State["ffiTargetEndpoint"],
    lastGcScopeCount: snap.lastGcScopeCount,
  };
}

function rebuildEscalationOwners(
  threads: State["threads"],
): State["escalationOwners"] {
  const out: Record<string, string> = {};
  for (const [threadId, thread] of Object.entries(threads)) {
    if (thread === undefined) continue;
    if (thread.kind !== "external" && thread.kind !== "agent") continue;
    for (const escalationId of Object.values(thread.pendingEscalations)) {
      out[escalationId as unknown as string] = threadId;
    }
  }
  return out;
}
