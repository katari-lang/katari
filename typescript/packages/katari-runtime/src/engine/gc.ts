// Intra-entity mark-and-sweep GC over the CORE-global scope + closure store.
//
// Cross-entity / persistence GC is gone (docs/2026-06-08-scope-closure-entity.md
// §5): entity release cascade-drops the scopes / closures it still owns, and
// ascent moves escaping ones to the parent. What remains is an intra-entity
// transient reclamation: a long-running entity (a big `for`, a long
// orchestrator) accumulates transient scopes mid-life, so a mark-sweep still
// runs — but ONLY over the scopes the CURRENT entity owns. Parent-owned
// (inherited / captured-from-ancestor) scopes are roots from this entity's view
// and must never be touched.
//
// Roots = this entity's live threads' scope chains + closures it owns reachable
// from a live value (computed inside `collectEntityGarbage`).

import type { ScopeId } from "./id.js";
import type { State } from "./state.js";
import { type CoreStore, collectEntityGarbage, shouldGc as shouldGcStore } from "./store.js";

/** Decide whether GC should run after this applyEvent (this entity's owned
 *  count grew past the heuristic, or no live threads remain). */
export function shouldGc(state: State, store: CoreStore): boolean {
  if (state.threadCount === 0) return false; // terminal: the entity cascade drops everything
  return shouldGcStore(store, state.selfEntity, state.lastGcScopeCount);
}

/** Sweep the scopes + closures owned by this shard's entity, rooted at its live
 *  threads' scope chains. Updates the GC heuristic baseline. */
export function collectGarbage(state: State, store: CoreStore): void {
  const roots: ScopeId[] = [];
  for (const t of Object.values(state.threads)) {
    if (t !== undefined) roots.push(t.scopeId);
  }
  state.lastGcScopeCount = collectEntityGarbage(store, state.selfEntity, roots);
}
