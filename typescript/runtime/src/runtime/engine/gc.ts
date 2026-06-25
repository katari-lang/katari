// Intra-instance scope GC: reclaim the scopes a `core` instance owns but no longer references. Scopes are
// allocated as an instance runs (one per spawned block) and only freed wholesale at the instance's teardown
// (the drop cascade); without this, a long-lived instance accumulates the scopes of every sub-thread that has
// already completed. The collector runs per core instance, at its turn boundary:
//
//   - MARK every scope reachable from the instance — each thread's own scope (and its lexical-ancestor chain)
//     plus every scope a `closure` captured in the instance's live values references (a value held in a
//     thread's state — a `for` / `parallel` accumulator, a `handle` / `for` state, a deferred cancel action —
//     or in any reachable scope's variable bindings), transitively.
//   - FREE the scopes the instance OWNS that the mark did not reach. (Scopes owned by another instance, or in
//     transit between owners (`owner = null`), are never touched — only this instance's own dead scopes.)
//
// This is sound because anything that could still reference one of the instance's scopes keeps the instance
// suspended: a child reading a scope through a closure argument keeps its caller awaiting the delegateAck, so
// the caller still holds that closure in one of its own scopes (the value is bound to a variable, never
// dropped — bindings are single-assignment) until the child returns. So a scope unreachable from the
// instance at a quiesced turn boundary is unreachable for good.

import { type ScopeId, toScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import { reachableResources } from "./ascent.js";
import type { CancelExit, CoreInstance, ProjectStore, Thread } from "./types.js";

/** The scopes a `core` instance owns but no longer references — safe to free at its turn boundary. */
export function unreachableOwnedScopes(store: ProjectStore, instance: CoreInstance): ScopeId[] {
  const marked = new Set<ScopeId>();
  const worklist: ScopeId[] = [];
  const seedValue = (value: Value): void => {
    for (const scopeId of reachableResources(store, value).scopes) worklist.push(scopeId);
  };

  // Roots: every thread's scope, plus the values a thread / cancel-exit holds (an accumulated closure, a
  // pending request argument, a deferred return value — each may capture scopes the variable bindings don't).
  for (const thread of Object.values(instance.threads)) {
    worklist.push(thread.scopeId);
    for (const value of threadValues(thread)) seedValue(value);
  }
  for (const exit of Object.values(instance.cancelExits)) {
    for (const value of cancelExitValues(exit)) seedValue(value);
  }

  // Mark: walk each scope's lexical-ancestor chain and the closures its bindings capture, transitively.
  while (worklist.length > 0) {
    const scopeId = worklist.pop();
    if (scopeId === undefined) break;
    if (marked.has(scopeId)) continue;
    marked.add(scopeId);
    const scope = store.scopes[scopeId];
    if (scope === undefined) continue;
    if (scope.parentId !== null) worklist.push(scope.parentId);
    for (const value of Object.values(scope.values)) seedValue(value);
  }

  // Sweep: this instance's own scopes the mark did not reach.
  const dead: ScopeId[] = [];
  for (const key of Object.keys(store.scopes)) {
    const scopeId = toScopeId(Number(key));
    if (store.scopes[scopeId]?.owner === instance.id && !marked.has(scopeId)) dead.push(scopeId);
  }
  return dead;
}

/** The `Value`s a thread holds in its variant-specific state (the ones that can capture a scope). Bindings
 *  in scopes are reached separately; this covers values that live on the thread itself. */
function threadValues(thread: Thread): Value[] {
  switch (thread.kind) {
    case "for":
      return [
        ...Object.values(thread.collected),
        ...Object.values(thread.states),
        ...Object.values(thread.postCancelCollect).flatMap((entry) => [
          entry.value,
          ...Object.values(entry.modifiers),
        ]),
      ];
    case "handle":
      return [
        ...Object.values(thread.states),
        ...thread.pendingRequests.flatMap((request) =>
          request.argument !== null ? [request.argument] : [],
        ),
        ...Object.values(thread.postCancelActions).map((action) => action.value),
      ];
    case "parallel":
      return Object.values(thread.collected);
    default:
      return [];
  }
}

/** The `Value`s a deferred cancel-exit carries (a return / break value held until the subtree tears down). */
function cancelExitValues(exit: CancelExit): Value[] {
  switch (exit.kind) {
    case "returnInstance":
    case "completeWith":
      return [exit.value];
    default:
      return [];
  }
}
