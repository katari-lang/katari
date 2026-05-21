// Closure: machine-local first-class object that pairs a block id with a
// captured lexical scope id. Reachable from `Value { kind: "closure" }`
// through the `closureId` field; the actual record lives in `state.closures`.
//
// Two reasons closures are id-indirected (rather than inlined into Value):
//   1. Agent-call-via-closure: a `BlockDelegate` with `delegateTargetValue`
//      resolves a VarId that holds a closure value, then needs an opaque
//      handle (`closureId`) to ship through the delegate event.
//   2. GC: a closure becomes unreachable when no live Value still references
//      its id, identical to scope reachability via parent / values graph.

import type { BlockId } from "../ir/types.js";
import type { ClosureId, ScopeId } from "./id.js";

export type ClosureRecord = {
  id: ClosureId;
  blockId: BlockId;
  scopeId: ScopeId;
};
