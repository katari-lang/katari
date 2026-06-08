// Closure: a first-class object pairing a body block id with a captured lexical
// scope id. Reachable from `Value { kind: "closure", closureId }` through the
// `closureId` field; the record itself lives in the CORE-global closure store
// (one per project actor, owned by an entity — NOT per-shard `State`; see
// docs/2026-06-08-scope-closure-entity.md).
//
// Why closures are id-indirected (rather than inlined into Value):
//   1. Closure CALL: a `BlockDelegate` with `delegateTargetValue` resolves a
//      VarId holding a closure value, then spawns the closure's body as a thread
//      in the CURRENT shard over the captured scope (in-shard, no serialize).
//   2. Ownership / GC: a closure is owned by an entity and cascade-drops with it;
//      the intra-entity GC collects an owned closure once no live Value in the
//      entity references its id.

import type { BlockId } from "../ir/types.js";
import type { ClosureId, EntityId, ScopeId } from "./id.js";

export type ClosureRecord = {
  id: ClosureId;
  blockId: BlockId;
  /** The scope the closure captured (= the body scope's parent on a call). */
  scopeId: ScopeId;
  /**
   * The snapshot (code version) the body block lives in. Carried so the closure
   * stays self-describing for the at-rest / cross-server form and for a cold
   * load that resolves the block against the right IR. On the warm in-shard call
   * path this equals the calling shard's snapshot (a run tree is single-snapshot).
   */
  snapshot: string;
  /**
   * The entity that owns this closure (see {@link import("./scope.js").Scope}).
   * Rises to an ancestor on escape; `null` while in-transit mid-ascent.
   */
  owner: EntityId | null;
};
