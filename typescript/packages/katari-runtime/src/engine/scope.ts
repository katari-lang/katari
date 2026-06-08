// Scope: lexical-binding tree node. Stored as plain data.
//
// Scopes form a tree via `parentId`. Variable lookup walks the parent chain.
// Closures capture a scopeId; the GC traces those refs through Value to
// keep captured scopes alive.
//
// A Scope is a CORE-global, entity-owned resource (one store per project actor,
// shared across the project's shards — NOT a field of the per-shard `State`; see
// docs/2026-06-08-scope-closure-entity.md). `owner` is the entity that created
// it; ownership rises to an ancestor when an escaping closure carries the scope
// up (value-driven ascent, mirroring blob refs). Entity release cascade-drops
// the scopes it still owns.

import type { Json } from "../json.js";
import type { EntityId, ScopeId } from "./id.js";
import type { Value } from "./value.js";

// `V` parameterises the embedded `Value` so the storage boundary can
// instantiate `Scope<EncryptedValue>` for the encrypted at-rest form. The
// live engine uses the default `Scope = Scope<Value>`; only the persistence
// codec picks a different `V`. See `mapScopeValues` in snapshot.ts.
export type Scope<V = Value> = {
  id: ScopeId;
  parentId: ScopeId | null;
  /**
   * The entity that owns this scope. Starts as the entity that created it
   * (`State.selfEntity` at creation); rises to an ancestor on closure escape
   * (ascent), or to `null` while in-transit mid-ascent (mirrors a blob ref's
   * `owner_entity_id`). The intra-entity GC only sweeps owned scopes; a parent-
   * owned (inherited / captured-from-ancestor) scope is a root from this
   * entity's view.
   */
  owner: EntityId | null;
  /**
   * VarId → Value map, stored as a plain object so Immer can treat it as
   * structural data. `Map` would also work but adds friction with Immer's
   * draft producers.
   */
  values: Record<number, V>;
  /**
   * The ambient generic substitution of the enclosing agent activation, set on
   * an agent's root scope from the inbound `delegate` event's `generics`. Inner
   * (inline) bodies inherit it via the scope chain; a `statementApplyGenerics`
   * fills its template `$generic` placeholders against the nearest one.
   */
  ambientGenerics?: Record<string, Json>;
};
