// CoreStore: the CORE-global scope + closure store.
//
// One store per project actor (CoreModule), shared across all the project's
// shards — NOT a field of the per-shard `State` (docs/2026-06-08-scope-closure-
// entity.md). A closure call spawns the body as a thread in the CURRENT shard
// over the captured scope, which lives here (owned by whatever entity created
// it, still alive) — so `use handler` completes in-shard with no serialize.
//
// Scopes / closures are entity-owned (like blob refs): created owned by the
// running entity, ascend to a parent when an escaping closure value carries them
// up, and cascade-drop when the owner entity is released. This module holds the
// pure operations the engine + CoreModule share: allocation, reachability for
// the intra-entity GC, and the transitive set an escaping value drags along.

import type { ClosureRecord } from "./closure.js";
import { type ClosureId, createScopeId, type EntityId, type ScopeId } from "./id.js";
import type { Scope } from "./scope.js";
import { collectClosures, collectRefs, type RefHandle, type Value } from "./value.js";

/**
 * The CORE-global scope + closure store. Plain data (Record-of-data) so the
 * persistence codec can map it without OO ceremony. Mutated in place by the
 * engine within a quantum; the CoreModule owns the live instance, persists the
 * running entity's owned slice per quantum, and rolls back on a poisoned tick.
 */
export type CoreStore = {
  /** ScopeId → Scope. */
  scopes: Record<ScopeId, Scope>;
  /** ClosureId → ClosureRecord. */
  closures: Record<ClosureId, ClosureRecord>;
};

export function emptyStore(): CoreStore {
  return { scopes: {}, closures: {} };
}

// ─── Allocation ──────────────────────────────────────────────────────────────

/** Allocate a fresh scope owned by `owner`, returning its id. */
export function allocScope(
  store: CoreStore,
  parentId: ScopeId | null,
  owner: EntityId | null,
): ScopeId {
  const id = createScopeId();
  store.scopes[id] = { id, parentId, values: {}, owner };
  return id;
}

/** Register a closure record (caller minted the id). */
export function putClosure(store: CoreStore, record: ClosureRecord): void {
  store.closures[record.id] = record;
}

// ─── Lookup ──────────────────────────────────────────────────────────────────

// Hard upper bound on scope-chain depth to catch a corrupt store (a cycle in
// parentId). Real programs nest 10-20 frames; 1000 is far above anything legal
// lowering reaches. Above that we fail loudly rather than spin.
const MAX_SCOPE_DEPTH = 1000;

/** Resolve `varId` by walking the scope chain from `scopeId` up its parents. */
export function lookupVar(store: CoreStore, scopeId: ScopeId, varId: number): Value {
  let cur: ScopeId | null = scopeId;
  let depth = 0;
  while (cur !== null) {
    if (depth++ > MAX_SCOPE_DEPTH) {
      throw new Error(
        `engine: scope chain from ${scopeId} exceeded ${MAX_SCOPE_DEPTH} frames while looking up var ${varId} (possible cycle in scope.parentId)`,
      );
    }
    const sc: Scope | undefined = store.scopes[cur];
    if (sc === undefined) {
      throw new Error(`engine: scope ${cur} not found while looking up var ${varId}`);
    }
    const v = sc.values[varId];
    if (v !== undefined) return v;
    cur = sc.parentId;
  }
  throw new Error(`engine: var ${varId} not found in scope ${scopeId} or ancestors`);
}

/** Find the nearest `ambientGenerics` walking from `scopeId` up its parents. */
export function lookupAmbient(
  store: CoreStore,
  scopeId: ScopeId,
): Record<string, import("../json.js").Json> {
  let cur: ScopeId | null = scopeId;
  let depth = 0;
  while (cur !== null) {
    if (depth++ > MAX_SCOPE_DEPTH) break;
    const sc: Scope | undefined = store.scopes[cur];
    if (sc === undefined) break;
    if (sc.ambientGenerics !== undefined) return sc.ambientGenerics;
    cur = sc.parentId;
  }
  return {};
}

// ─── Transitive closure set (ascent / cold load) ─────────────────────────────

/** The transitive set of scopes + closures reachable from `seed` closures: each
 *  closure's captured scope chain, plus every nested closure those scopes hold,
 *  recursively. Used by ascent (the set an escaping value drags up) and cold
 *  load (the set a referenced closure pulls in). Robust to a missing record (a
 *  cold load may not have a given owner's slice yet — the caller loads more). */
export function reachableFromClosures(
  store: CoreStore,
  seed: ReadonlyArray<ClosureId>,
): { scopes: Set<ScopeId>; closures: Set<ClosureId> } {
  const scopes = new Set<ScopeId>();
  const closures = new Set<ClosureId>();
  const closureWork = [...seed];
  const scopeWork: ScopeId[] = [];

  const visitScope = (id: ScopeId | null): void => {
    if (id === null || scopes.has(id)) return;
    scopes.add(id);
    scopeWork.push(id);
  };
  const visitClosure = (id: ClosureId): void => {
    if (closures.has(id)) return;
    closures.add(id);
    closureWork.push(id);
  };

  while (closureWork.length > 0 || scopeWork.length > 0) {
    while (closureWork.length > 0) {
      const cid = closureWork.pop()!;
      closures.add(cid);
      const rec = store.closures[cid];
      if (rec !== undefined) visitScope(rec.scopeId);
    }
    while (scopeWork.length > 0) {
      const sid = scopeWork.pop()!;
      const sc = store.scopes[sid];
      if (sc === undefined) continue;
      visitScope(sc.parentId);
      for (const v of Object.values(sc.values)) {
        if (v !== undefined) for (const cid of collectClosures(v)) visitClosure(cid);
      }
    }
  }
  return { scopes, closures };
}

// ─── Ascent (escape detach / claim — value-driven, mirrors blob refs) ────────

/**
 * Re-own the transitive scope + closure set an escaping `value` carries (the
 * closures in `value`, each closure's captured scope chain, and the nested
 * closures those scopes hold), moving every member currently owned by
 * `fromOwner` to `toOwner`. Returns the content-ref handles found INSIDE those
 * scopes (file / string refs a captured value holds), so the caller re-owns them
 * in the value store with the same `fromOwner → toOwner` transition.
 *
 *   - detach (child terminal):  reownEscaping(store, ackValue, E_child, null)
 *   - claim  (parent on ack):   reownEscaping(store, ackValue, null, E_parent)
 *
 * A member owned by neither (a captured scope owned by a still-alive ancestor)
 * is left untouched — only `fromOwner`'s members move, mirroring `reownRefs`.
 */
export function reownEscaping(
  store: CoreStore,
  value: Value,
  fromOwner: EntityId | null,
  toOwner: EntityId | null,
): RefHandle[] {
  const { scopes, closures } = reachableFromClosures(store, collectClosures(value));
  const refs: RefHandle[] = [];
  for (const sid of scopes) {
    const sc = store.scopes[sid];
    if (sc === undefined || sc.owner !== fromOwner) continue;
    sc.owner = toOwner;
    for (const v of Object.values(sc.values)) if (v !== undefined) refs.push(...collectRefs(v));
  }
  for (const cid of closures) {
    const c = store.closures[cid];
    if (c === undefined || c.owner !== fromOwner) continue;
    c.owner = toOwner;
  }
  return refs;
}

/** Drop every scope + closure owned by `entity` (the entity-release cascade).
 *  Detached (`owner = null`, mid-ascent) members are NOT dropped. */
export function dropOwned(store: CoreStore, entity: EntityId): void {
  for (const id of Object.keys(store.scopes) as ScopeId[]) {
    if (store.scopes[id]!.owner === entity) delete store.scopes[id];
  }
  for (const id of Object.keys(store.closures) as ClosureId[]) {
    if (store.closures[id]!.owner === entity) delete store.closures[id];
  }
}

/** Deep-clone the slice of scopes + closures owned by `entity` (for a poisoned-
 *  quantum rollback: the in-memory store is mutated in place, so we snapshot the
 *  entity's owned slice before applyEvent and restore it on a throw). */
export function snapshotOwned(
  store: CoreStore,
  entity: EntityId,
): { scopes: Record<ScopeId, Scope>; closures: Record<ClosureId, ClosureRecord> } {
  const scopes: Record<ScopeId, Scope> = {};
  const closures: Record<ClosureId, ClosureRecord> = {};
  for (const [id, sc] of Object.entries(store.scopes)) {
    if (sc.owner === entity) scopes[id as ScopeId] = structuredClone(sc);
  }
  for (const [id, c] of Object.entries(store.closures)) {
    if (c.owner === entity) closures[id as ClosureId] = structuredClone(c);
  }
  return { scopes, closures };
}

/** Restore `entity`'s owned slice from a {@link snapshotOwned} snapshot: drop
 *  every currently-`entity`-owned member (created / mutated this quantum) and
 *  re-insert the committed ones. */
export function restoreOwned(
  store: CoreStore,
  entity: EntityId,
  snapshot: { scopes: Record<ScopeId, Scope>; closures: Record<ClosureId, ClosureRecord> },
): void {
  dropOwned(store, entity);
  for (const [id, sc] of Object.entries(snapshot.scopes)) store.scopes[id as ScopeId] = sc;
  for (const [id, c] of Object.entries(snapshot.closures)) store.closures[id as ClosureId] = c;
}

// ─── Intra-entity GC (owned scopes only) ─────────────────────────────────────
//
// A long-running entity (a big `for`, a long orchestrator) accumulates transient
// scopes mid-life; cascade only fires at terminal. So a mark-sweep still runs,
// but only over the scopes THIS entity owns — it must NOT touch parent-owned
// (inherited / captured-from-ancestor) scopes, which are roots from this
// entity's view. Roots = the entity's live threads' scope chains (stopping at
// the first non-owned scope) + closures the entity owns reachable from a live
// value.

const GC_GROWTH_FACTOR = 1.5;
const GC_MIN_DELTA = 32;

/** Count the scopes + closures `entity` owns in the store. */
export function ownedCount(store: CoreStore, entity: EntityId): number {
  let n = 0;
  for (const s of Object.values(store.scopes)) if (s.owner === entity) n++;
  for (const c of Object.values(store.closures)) if (c.owner === entity) n++;
  return n;
}

/** GC heuristic: sweep when this entity's owned count grew past the threshold. */
export function shouldGc(store: CoreStore, entity: EntityId, lastGcCount: number): boolean {
  return ownedCount(store, entity) > lastGcCount * GC_GROWTH_FACTOR + GC_MIN_DELTA;
}

/**
 * Mark-sweep the scopes + closures owned by `entity`, given the live thread
 * root scope ids of that entity. Removes unreachable owned scopes / closures
 * from the store and returns the surviving owned count (for the GC heuristic).
 *
 * Roots: each live thread's scope chain, walked up but stopping at the first
 * non-`entity`-owned scope (a parent-owned scope is a root, kept whole — we do
 * not own it). A closure owned by `entity` is reachable iff a reachable scope's
 * value graph references its id; an unreachable owned closure is collected.
 */
export function collectEntityGarbage(
  store: CoreStore,
  entity: EntityId,
  rootScopeIds: ReadonlyArray<ScopeId>,
): number {
  const reachableScopes = new Set<ScopeId>();
  const reachableClosures = new Set<ClosureId>();
  const scopeWork: ScopeId[] = [];
  const closureWork: ClosureId[] = [];

  const visitScope = (id: ScopeId | null): void => {
    if (id === null || reachableScopes.has(id)) return;
    const sc = store.scopes[id];
    if (sc === undefined) return;
    reachableScopes.add(id);
    // Walk the parent chain for value resolution regardless of ownership, but
    // we only ever SWEEP owned scopes (a non-owned ancestor is never deleted).
    scopeWork.push(id);
  };
  const visitClosure = (id: ClosureId): void => {
    if (reachableClosures.has(id)) return;
    reachableClosures.add(id);
    closureWork.push(id);
  };

  for (const id of rootScopeIds) visitScope(id);

  while (scopeWork.length > 0 || closureWork.length > 0) {
    while (scopeWork.length > 0) {
      const sid = scopeWork.pop()!;
      const sc = store.scopes[sid];
      if (sc === undefined) continue;
      visitScope(sc.parentId);
      for (const v of Object.values(sc.values)) {
        if (v !== undefined) for (const cid of collectClosures(v)) visitClosure(cid);
      }
    }
    while (closureWork.length > 0) {
      const cid = closureWork.pop()!;
      const rec = store.closures[cid];
      if (rec !== undefined) visitScope(rec.scopeId);
    }
  }

  let surviving = 0;
  for (const id of Object.keys(store.scopes) as ScopeId[]) {
    const sc = store.scopes[id]!;
    if (sc.owner !== entity) continue; // never sweep a non-owned scope
    if (reachableScopes.has(id)) {
      surviving++;
    } else {
      delete store.scopes[id];
    }
  }
  for (const id of Object.keys(store.closures) as ClosureId[]) {
    const rec = store.closures[id]!;
    if (rec.owner !== entity) continue;
    if (reachableClosures.has(id)) {
      surviving++;
    } else {
      delete store.closures[id];
    }
  }
  return surviving;
}
