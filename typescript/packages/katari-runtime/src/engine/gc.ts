// Mark-and-sweep GC for scopes + closures.
//
// Scopes form a tree (`parentId`); closures live in `state.closures` and
// hold a ScopeId. Tuples / arrays / tagged values can hold further refs
// transitively. The GC root set is every live thread's scopeId. From
// there we trace parent chains + every Value graph in scope.values, with
// closure-id derefs adding the captured scope (and its parent chain).
//
// Closures are reachable iff some live Value has `closure { closureId }`.
// Unreachable closures are dropped from `state.closures`.
//
// Invocation: the runner calls `collectGarbage` at the end of an
// `applyEvent` drain when scope count growth crosses a heuristic
// threshold.

import type { ClosureId, ScopeId } from "./id.js";
import type { Scope } from "./scope.js";
import type { State } from "./state.js";
import type { Value } from "./value.js";

const GC_GROWTH_FACTOR = 1.5;
const GC_MIN_DELTA = 32;

/**
 * Decide whether GC should run after this applyEvent.
 *
 * Heuristics:
 *   - if no live threads remain, sweep immediately (nothing is reachable)
 *   - else, only sweep when scope count has grown past
 *     `lastGcScopeCount * GROWTH_FACTOR + MIN_DELTA`
 */
export function shouldGc(state: State): boolean {
  if (state.threadCount === 0) return state.scopeCount > 0;
  return state.scopeCount > state.lastGcScopeCount * GC_GROWTH_FACTOR + GC_MIN_DELTA;
}

/** Mutate the Immer draft to remove unreachable scopes + closures. */
export function collectGarbage(state: State): void {
  const reachableScopes = new Set<ScopeId>();
  const reachableClosures = new Set<number>();
  const worklist: ScopeId[] = [];

  const visitScope = (scopeId: ScopeId | null): void => {
    if (scopeId === null) return;
    if (reachableScopes.has(scopeId)) return;
    reachableScopes.add(scopeId);
    worklist.push(scopeId);
  };

  const visitClosure = (closureId: ClosureId): void => {
    const num = closureId;
    if (reachableClosures.has(num)) return;
    reachableClosures.add(num);
    const cl = state.closures[num];
    if (cl !== undefined) visitScope(cl.scopeId);
  };

  // Roots: every live thread's scopeId.
  for (const t of Object.values(state.threads)) {
    if (t === undefined) continue;
    visitScope(t.scopeId);
  }

  while (worklist.length > 0) {
    const scopeId = worklist.pop()!;
    const sc = state.scopes[scopeId] as Scope | undefined;
    if (sc === undefined) continue;

    visitScope(sc.parentId);

    for (const v of Object.values(sc.values)) {
      if (v !== undefined) traceValue(v, visitScope, visitClosure);
    }
  }

  for (const scopeId of Object.keys(state.scopes) as ScopeId[]) {
    if (!reachableScopes.has(scopeId)) {
      delete state.scopes[scopeId];
    }
  }
  for (const closureKey of Object.keys(state.closures)) {
    const closureId = Number(closureKey) as ClosureId;
    if (!reachableClosures.has(closureId)) {
      delete state.closures[closureId];
    }
  }

  state.scopeCount = reachableScopes.size;
  state.lastGcScopeCount = reachableScopes.size;
}

function traceValue(
  v: Value,
  visitScope: (s: ScopeId | null) => void,
  visitClosure: (c: ClosureId) => void,
): void {
  switch (v.kind) {
    case "closure":
      visitClosure(v.closureId);
      return;
    case "array":
      for (const e of v.elements) traceValue(e, visitScope, visitClosure);
      return;
    case "tagged":
      for (const f of Object.values(v.fields))
        traceValue(f, visitScope, visitClosure);
      return;
    case "record":
      for (const e of Object.values(v.entries))
        traceValue(e, visitScope, visitClosure);
      return;
    default:
      return;
  }
}
