// ScopeStore — the runtime → host hand-off for the CORE-global scope + closure
// store's at-rest mirror (docs/2026-06-08-scope-closure-entity.md §6).
//
// Scopes / closures live warm in memory on the CoreModule (one store per project
// actor). This store is their write-through, per-owner-entity durable mirror,
// for crash recovery + a cold load of an entity. It mirrors the value store's
// `refs`: each row is owned by exactly one entity, or transiently by NULL
// mid-ascent; an entity's release cascade-drops its still-owned rows.
//
// Rows are individual scopes / closures (not a per-entity blob) so an ascent that
// re-owns only the escaping subset is a simple owner change. Captured scope
// values are encrypted at rest (a captured `secret` → `$envelope`).
//
// `projectId` / `ownerEntityId` are plain strings (ambient context / opaque id)
// to keep the runtime decoupled from the api-server's branded ids.

import type { ClosureId, EntityId, ScopeId } from "../engine/id.js";
import type { BlockId } from "../ir/types.js";
import type { Json } from "../json.js";
import type { EncryptedValue } from "../value-secret-codec.js";

/** A scope row, owned by an entity (or NULL mid-ascent). Values are encrypted. */
export type PersistedScope = {
  id: ScopeId;
  parentId: ScopeId | null;
  owner: EntityId | null;
  values: Record<number, EncryptedValue>;
  ambientGenerics?: Record<string, Json>;
};

/** A closure row, owned by an entity (or NULL mid-ascent). No embedded values. */
export type PersistedClosure = {
  id: ClosureId;
  blockId: BlockId;
  scopeId: ScopeId;
  snapshot: string;
  owner: EntityId | null;
};

export interface ScopeStore {
  /**
   * Upsert scope + closure rows by id (the per-quantum write-through, an ascent
   * claim, and the in-transit detach all funnel through this — the row's `owner`
   * is whatever the warm store currently holds).
   */
  upsert(
    projectId: string,
    scopes: ReadonlyArray<PersistedScope>,
    closures: ReadonlyArray<PersistedClosure>,
  ): Promise<void>;
  /** Drop every scope + closure owned by `entity` (the entity-release cascade). */
  deleteOwned(projectId: string, entity: EntityId): Promise<void>;
  /** Load every scope + closure owned by `entity` (cold load of the entity). */
  loadOwned(
    projectId: string,
    entity: EntityId,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }>;
  /** Load specific scopes / closures by id (transitive cold load across owners). */
  loadByIds(
    projectId: string,
    scopeIds: ReadonlyArray<ScopeId>,
    closureIds: ReadonlyArray<ClosureId>,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }>;
  /**
   * Crash backstop: delete every in-transit row (`owner IS NULL`) — detached
   * mid-ascent and never claimed (the claim was lost to a crash). MUST run only
   * at boot, before traffic (a live in-transit row would be wrongly collected).
   */
  sweepDetached(projectId: string): Promise<void>;
}
