// In-memory `ScopeStore` (the at-rest mirror of the CORE-global scope + closure
// store). Used by tests and the memory `Storage` backend.
//
// Rows mirror the entity model's `refs`: each scope / closure is owned by exactly
// one entity (or NULL mid-ascent). Entity CASCADE is simulated by `deleteOwned`,
// which the memory `EntityRepo.delete` also calls (so dropping an entity drops
// its still-owned scopes / closures, like its refs).

import type {
  ClosureId,
  EntityId,
  PersistedClosure,
  PersistedScope,
  ScopeId,
  ScopeStore,
} from "@katari-lang/runtime";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

type ScopeRow = { projectId: string; scope: PersistedScope };
type ClosureRow = { projectId: string; closure: PersistedClosure };

const key = (projectId: string, id: string): string => `${projectId}|${id}`;

export class InMemoryScopeStore implements ScopeStore {
  // Public so the `Storage` facade can snapshot/restore for `withTransaction`.
  scopes = new Map<string, ScopeRow>();
  closures = new Map<string, ClosureRow>();

  async upsert(
    projectId: string,
    scopes: ReadonlyArray<PersistedScope>,
    closures: ReadonlyArray<PersistedClosure>,
  ): Promise<void> {
    for (const sc of scopes) {
      this.scopes.set(key(projectId, sc.id), { projectId, scope: clone(sc) });
    }
    for (const c of closures) {
      this.closures.set(key(projectId, c.id), { projectId, closure: clone(c) });
    }
  }

  async deleteOwned(projectId: string, entity: EntityId): Promise<void> {
    for (const [k, row] of [...this.scopes]) {
      if (row.projectId === projectId && row.scope.owner === entity) this.scopes.delete(k);
    }
    for (const [k, row] of [...this.closures]) {
      if (row.projectId === projectId && row.closure.owner === entity) this.closures.delete(k);
    }
  }

  async loadOwned(
    projectId: string,
    entity: EntityId,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }> {
    const scopes = [...this.scopes.values()]
      .filter((r) => r.projectId === projectId && r.scope.owner === entity)
      .map((r) => clone(r.scope));
    const closures = [...this.closures.values()]
      .filter((r) => r.projectId === projectId && r.closure.owner === entity)
      .map((r) => clone(r.closure));
    return { scopes, closures };
  }

  async loadByIds(
    projectId: string,
    scopeIds: ReadonlyArray<ScopeId>,
    closureIds: ReadonlyArray<ClosureId>,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }> {
    const scopes: PersistedScope[] = [];
    for (const id of scopeIds) {
      const row = this.scopes.get(key(projectId, id));
      if (row !== undefined) scopes.push(clone(row.scope));
    }
    const closures: PersistedClosure[] = [];
    for (const id of closureIds) {
      const row = this.closures.get(key(projectId, id));
      if (row !== undefined) closures.push(clone(row.closure));
    }
    return { scopes, closures };
  }

  async sweepDetached(projectId: string): Promise<void> {
    for (const [k, row] of [...this.scopes]) {
      if (row.projectId === projectId && row.scope.owner === null) this.scopes.delete(k);
    }
    for (const [k, row] of [...this.closures]) {
      if (row.projectId === projectId && row.closure.owner === null) this.closures.delete(k);
    }
  }

  // ── entity CASCADE (called by the memory EntityRepo.delete) ──────────────

  /** Delete every scope / closure owned by `entity` (the FK CASCADE, in code). */
  deleteOwnedSync(projectId: string, entity: string): void {
    for (const [k, row] of [...this.scopes]) {
      if (row.projectId === projectId && row.scope.owner === entity) this.scopes.delete(k);
    }
    for (const [k, row] of [...this.closures]) {
      if (row.projectId === projectId && row.closure.owner === entity) this.closures.delete(k);
    }
  }
}
