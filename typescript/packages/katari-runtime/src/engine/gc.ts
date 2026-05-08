// Mark-and-sweep GC for scopes.
//
// Scopes form a tree (`parentId`); closures, tuples, arrays, and tagged
// values can hold scope refs through their fields/elements. The GC root
// set is every live thread's scopeId. From there we trace parent chains
// + every scopeId reachable through Value graphs in scope.values.
//
// Invocation: the runner calls `collectGarbage` at the end of an
// `applyEvent` drain when scope count growth crosses a heuristic
// threshold.

import type { Draft } from "immer";
import type { ScopeId } from "./id.js";
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
  const scopeCount = Object.keys(state.scopes).length;
  if (Object.keys(state.threads).length === 0) return scopeCount > 0;
  return scopeCount > state.lastGcScopeCount * GC_GROWTH_FACTOR + GC_MIN_DELTA;
}

/** Mutate the Immer draft to remove unreachable scopes. */
export function collectGarbage(state: Draft<State>): void {
  const reachable = new Set<ScopeId>();
  const worklist: ScopeId[] = [];

  // Roots: every live thread's scopeId.
  for (const t of Object.values(state.threads)) {
    if (t === undefined) continue;
    if (!reachable.has(t.scopeId)) {
      reachable.add(t.scopeId);
      worklist.push(t.scopeId);
    }
  }

  while (worklist.length > 0) {
    const scopeId = worklist.pop()!;
    const sc = state.scopes[scopeId] as Scope | undefined;
    if (sc === undefined) continue;

    if (sc.parentId !== null && !reachable.has(sc.parentId)) {
      reachable.add(sc.parentId);
      worklist.push(sc.parentId);
    }

    for (const v of Object.values(sc.values)) {
      if (v !== undefined) traceValue(v, reachable, worklist);
    }
  }

  for (const scopeId of Object.keys(state.scopes)) {
    if (!reachable.has(scopeId as ScopeId)) {
      delete state.scopes[scopeId];
    }
  }

  state.lastGcScopeCount = Object.keys(state.scopes).length;
}

function traceValue(
  v: Value,
  reachable: Set<ScopeId>,
  worklist: ScopeId[],
): void {
  switch (v.kind) {
    case "closure":
      if (!reachable.has(v.scopeId)) {
        reachable.add(v.scopeId);
        worklist.push(v.scopeId);
      }
      return;
    case "tuple":
    case "array":
      for (const e of v.elements) traceValue(e, reachable, worklist);
      return;
    case "tagged":
      for (const f of Object.values(v.fields)) traceValue(f, reachable, worklist);
      return;
    default:
      return;
  }
}
