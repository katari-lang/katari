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
//   - EXCEPT the candidates a live thread of ANOTHER instance still evaluates in (or lexically encloses), which
//     the sweep un-condemns — see `retainLiveEnvironments`.
//
// Bindings are single-assignment, and the one way a binding disappears early — a compiler-inserted `drop` op —
// removes only a binding the compiler proved unreadable, so reachability computed here can only shrink turn
// over turn, never grow back. A scope unreachable from the instance at a quiesced turn boundary is therefore
// unreachable *from this instance* for good.
//
// Unreachable-from-the-owner is NOT the same as dead, though — which is why the sweep filters. The original
// argument here was that whoever else could still reference one of the instance's scopes keeps the instance
// suspended (a child reading a scope through a closure argument keeps its caller awaiting the delegateAck, so
// the caller still holds that closure in one of its own scopes until the child returns). That holds for a
// closure passed DOWN a delegation, but not for one riding an escalation UP: a value crossing a boundary
// releases the scopes it captures to the receiver (`ResourcePool.release` / `reown`), so a request argument
// relayed through a chain of instances lands its captured environment — the LIVE lexical scopes of the raiser
// and every relaying hop, all of them still running and still writing into those scopes — on the ancestor that
// holds the handler. That ancestor answers the request, drops the payload, and its next sweep finds scopes it
// owns and cannot reach: the descendants' own working environments. Ownership rose; liveness did not follow it
// down. So the sweep asks the one question ownership can no longer answer — is any live thread still standing
// in this scope? — before freeing.

import type { InstanceId, ScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import { reachableResources } from "./ascent.js";
import { scopesOwnedBy } from "./scope.js";
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
  // The armed-but-not-yet-run finalizers' scopes (each spawned finalizer chains to one) outlive the threads
  // that armed them, so they are roots in their own right — otherwise a multi-turn finalizer would let GC
  // reclaim a later finalizer's enclosing scope. So is the value a `finalizing` completion defers (its
  // deferred delegateAck may return a closure / blob whose captured scopes must survive the drain).
  for (const armed of instance.finalizers) worklist.push(armed.scopeId);
  if (instance.phase.kind === "finalizing" && instance.phase.disposition.kind === "completed") {
    seedValue(instance.phase.disposition.value);
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

  // Sweep: this instance's own scopes the mark did not reach, minus the ones another instance's live threads
  // are still standing in (the header's ownership-is-not-liveness case). The retain pass runs only when there
  // is something to condemn, so a turn that frees nothing pays nothing for it.
  const dead = new Set<ScopeId>();
  for (const scopeId of scopesOwnedBy(store, instance.id)) {
    if (!marked.has(scopeId)) dead.add(scopeId);
  }
  if (dead.size > 0) retainLiveEnvironments(store, instance.id, dead);
  return [...dead];
}

/**
 * Un-condemn every candidate that is a live thread's lexical environment somewhere else in the project: for
 * each OTHER loaded instance, walk each of its threads' scope chains (and each armed finalizer's, which the
 * instance's own mark already treats as a root in its own right) and drop what they touch from `dead`. A thread
 * writes its bindings into the scope it evaluates in and reads through that scope's ancestors, so freeing any
 * of them under a running thread corrupts it — the crash is the thread's next write throwing `scope not found`.
 *
 * The walk is chain-only (no descent into the scopes' bound values): what it protects is exactly the
 * environment a live thread can still *reach lexically*. A closure a live thread merely holds in a variable
 * needs no protection here — that closure's chain is reachable from the holder's own scope, so the holder's own
 * sweep marks it, and only its OWNER's sweep can free it.
 *
 * `store.instances` holds every live core instance of the project (it is loaded wholesale on reactivation and
 * only shrinks at teardown), so this sees all of them, not just the warm few. The non-core instance kinds own
 * scopes but run no threads, and only an owner frees, so they need no representation here.
 */
function retainLiveEnvironments(
  store: ProjectStore,
  sweeper: InstanceId,
  dead: Set<ScopeId>,
): void {
  const visited = new Set<ScopeId>();
  const walkChain = (from: ScopeId): boolean => {
    let current: ScopeId | null = from;
    while (current !== null && !visited.has(current)) {
      visited.add(current);
      dead.delete(current);
      if (dead.size === 0) return true; // nothing left to condemn — stop early
      current = store.scopes[current]?.parentId ?? null;
    }
    return false;
  };
  for (const other of Object.values(store.instances)) {
    if (other.id === sweeper) continue; // its own threads are already mark roots
    for (const thread of Object.values(other.threads)) {
      if (walkChain(thread.scopeId)) return;
    }
    for (const armed of other.finalizers) {
      if (walkChain(armed.scopeId)) return;
    }
  }
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
