# Scope / Closure as CORE-global, entity-owned resources (v0.1.0)

Settles step 3 of the first-class-handler roadmap. Generalises the ref-ownership
of [entity-model](2026-06-01-entity-model.md) to **scopes and closures**: they
become **CORE-global** (one store per project actor, not per-shard) and **owned
by an entity**, exactly like blob refs. The eager closure-blob serialize (at
`make-closure`) and the per-invocation re-materialize are removed; serialization
happens only at-rest (checkpoint) and at a cross-server boundary (v0.2).

## 1. Why

A handler provider (`agent provide_session[R,E](...) { return handler[R,E]{...} }`)
and a `use handler {...}` are inherently CROSS-shard higher-order agents: the
provider runs in one shard, the continuation in another, the captured scope in a
third. Today every such hop serialises the captured scope to a content blob and
re-materialises it into a fresh shard — a blob round-trip per closure op, on the
hot path now that `use handler` is a higher-order application (commit `0323e1a`).

The fix is the entity model's own idea: a closure / scope is **owned by an
entity**, lives in a **CORE-global** in-memory store while warm, **ascends** to
the parent entity when it escapes (value-driven, §2 of the entity model), and is
**cascade-dropped** when its owner entity is released. No serialize on the hot
path; mark-sweep shrinks to intra-entity transient reclamation.

## 2. Model

- **Scope** and **ClosureRecord** are CORE-global: one `scopes` / `closures`
  store per **project actor** (CoreModule), shared across all the project's
  shards — NOT a field of the per-shard `State`. Each carries `owner: EntityId`.
- A **closure VALUE is `{ kind: "closure", closureId }`** — a machine-local id
  into the global `closures` store. The content-addressed `{ kind: "closure",
  ref }` blob form is GONE from the live value; it survives only as the at-rest
  serialised form (checkpoint / cross-server).
- A `ClosureRecord` is `{ id, blockId, capturedScopeId, owner }`; a `Scope`
  gains `owner: EntityId`. Both `owner`s start as the entity that created them.

## 3. Closure call = in-shard thread spawn over the global scope

A `BlockDelegate { target: delegateTargetValue }` whose value is a closure no
longer emits a cross-shard `delegate`. Instead the engine spawns the closure's
body (a `BlockAgent`) as an **AgentThread in the CURRENT shard's thread tree**,
its body scope inheriting (`parentId`) the closure's `capturedScopeId` — which
lives in the global store (owned by whatever entity created it, still alive).

So `use handler {...}`:
- foo's shard makes the provider + continuation closures (owner = foo's entity);
- the provider call spawns the provider body as a thread in foo's shard,
  inheriting the provider's captured scope (global);
- the provider's `k()` spawns the continuation body as a thread in foo's shard,
  inheriting the continuation's captured scope (global);
- requests bubble to the in-shard `BlockHandle`; `next` resumes — **all in-shard,
  no serialize, no cross-delegation escalation.** (return / break / next still
  route by the lexical target id, f911491 — now intra-shard via proxy.)

The closure-body AgentThread is a NON-root agent (it has a parent), so its
`return` proxies up to the lexical target (no delegation boundary). It is a
delegation root only when invoked across a true entity boundary (a closure value
that escaped to another entity — see §4).

## 4. Escape + ascent (value-driven, like refs)

A closure / scope **escapes** when its closure value leaves the owning entity in
a result (`delegateAck`) or `escalate` payload. On the owner's terminal:

- **detach** the escaping closures (those in `collectClosures(value)`) and their
  captured scope chains (transitively via `parentId` + nested closure values):
  `owner := NULL` (in-transit);
- the rest cascade away with the entity;
- the parent **claims** the result value's closures + their scope chains to its
  own entity on the ack.

Mirrors `detachRefs` / `claimRefs`. A scope's chain ascends as a unit (the
`owner(parent-scope) ≥ owner(child)` invariant holds because a child scope's
parent is always created no-later, by an ancestor entity).

## 5. GC

- **Cross-entity / persistence GC: gone.** Entity release cascade-drops the
  scopes / closures it still owns; ascent moves escaping ones to the parent. No
  cross-shard mark-sweep, no dead-owner reconcile, no closure-blob refcount.
- **Intra-entity transient reclamation: kept (shrunk).** A long-running entity
  (a big `for`, a long orchestrator) accumulates transient scopes mid-life;
  cascade only fires at terminal. So a mark-sweep still runs, but **only over the
  scopes the CURRENT entity owns** — it must NOT touch parent-owned (inherited /
  captured-from-ancestor) scopes, which are roots from this entity's view. Roots
  = the entity's live threads' scope chains (stopping at the first non-owned
  scope) + closures the entity owns that are reachable from a live value.

## 6. Persistence

Warm: the global store stays in memory; **no serialize while the project actor
is live** (single-process v0.1.0). At a quantum's end the **dirty scopes /
closures are persisted per owner entity** (a `scopes` blob/table keyed by
`owner_entity_id`, same shape as `refs` hang off entities). On a cold load of an
entity, its owned scopes / closures load with it. A closure captured by an
escaping value persists because its scope chain is claimed by a kept entity (the
run root) — identical to how refs persist. Cross-server (v0.2) is the only place
a closure serialises to a content blob on the wire.

Crash recovery: the DB is truth; reload the last checkpoint's entity-owned
scopes / closures and re-drive in-flight per the delegation table.

## 7. Touch points

- `engine/value.ts` — closure value `{ closureId }` (drop the live `ref` form).
- `engine/closure.ts` — `ClosureRecord` gains `owner`.
- `engine/scope.ts` — `Scope` gains `owner`.
- `engine/state.ts` — `scopes` / `closures` move OUT to a CORE-global store the
  CoreModule injects; `State` carries `selfEntity` (the running shard's entity)
  so `createScope` / `makeClosure` tag ownership.
- `engine/thread/ops/make-closure.ts` → inline (no async, no serialize): allocate
  a `ClosureRecord` owned by `selfEntity`.
- closure-call dispatch (`delegate.ts` / a new in-shard spawn path) — §3.
- `runner.ts` `resolveDelegateTarget` — closure target = in-shard spawn, not a
  fresh-shard materialize. The `closureRef` blob path is removed from the live
  engine (only the at-rest decode remains).
- `engine/gc.ts` — owned-scopes-only intra-entity mark-sweep (§5).
- ascent: `detachClosures` / `claimClosures` alongside the ref detach/claim in
  CoreModule's terminal / ack handling.
- `modules/core.ts` — own the global store; inject into each shard run; persist
  per-entity; ascent on terminal/ack; cross-shard scope reads resolve the store.
- `engine/snapshot.ts` / `closure-codec.ts` — at-rest serialize of entity-owned
  scopes / closures (the blob codec stays for at-rest + v0.2 cross-server only).
- value-store / entity-store / DB — a `scopes` owner table (mirror of `refs`).

## 8. Removed (no leftover)

The live content-addressed closure value (`{ kind: "closure", ref }`), the eager
`serializeClosure` at make-closure, the `closureRef` agent-def-id materialize
path, and the per-invocation fresh-shard closure materialize. The blob codec is
retained ONLY as the at-rest / cross-server serialise form.
