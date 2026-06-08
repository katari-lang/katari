// Postgres-backed `ScopeStore` over `scopes` / `closures` — the at-rest mirror
// of the CORE-global scope + closure store. Each row is owned by one entity
// (`owner_entity_id`, FK CASCADE) or NULL mid-ascent, mirroring `refs`. An entity
// release cascade-drops its still-owned rows; the boot sweep reaps detached
// (NULL-owner) rows whose ascent was lost to a crash.

import type {
  ClosureId,
  EntityId,
  PersistedClosure,
  PersistedScope,
  ScopeId,
  ScopeStore,
} from "@katari-lang/runtime";
import type postgres from "postgres";

type Sql = ReturnType<typeof postgres>;

// The `postgres` driver types `sql.json` against its own JSONValue; our payloads
// are plain JSON. Adapt at the call site.
function asJson(value: unknown): never {
  return value as never;
}

type ScopeRow = {
  id: string;
  owner_entity_id: string | null;
  parent_id: string | null;
  values: Record<number, unknown>;
  ambient_generics: Record<string, unknown> | null;
};
type ClosureRow = {
  id: string;
  owner_entity_id: string | null;
  block_id: number;
  captured_scope_id: string;
  snapshot: string;
};

function toScope(row: ScopeRow): PersistedScope {
  const scope: PersistedScope = {
    id: row.id as ScopeId,
    parentId: row.parent_id as ScopeId | null,
    owner: row.owner_entity_id as EntityId | null,
    values: row.values as PersistedScope["values"],
  };
  if (row.ambient_generics !== null) {
    scope.ambientGenerics = row.ambient_generics as PersistedScope["ambientGenerics"];
  }
  return scope;
}

function toClosure(row: ClosureRow): PersistedClosure {
  return {
    id: row.id as ClosureId,
    blockId: row.block_id as PersistedClosure["blockId"],
    scopeId: row.captured_scope_id as ScopeId,
    snapshot: row.snapshot,
    owner: row.owner_entity_id as EntityId | null,
  };
}

export class PgScopeStore implements ScopeStore {
  constructor(private readonly sql: Sql) {}

  async upsert(
    projectId: string,
    scopes: ReadonlyArray<PersistedScope>,
    closures: ReadonlyArray<PersistedClosure>,
  ): Promise<void> {
    for (const sc of scopes) {
      await this.sql`
        INSERT INTO scopes (project_id, id, owner_entity_id, parent_id, values, ambient_generics)
        VALUES (${projectId}, ${sc.id}, ${sc.owner}, ${sc.parentId},
                ${this.sql.json(asJson(sc.values))},
                ${sc.ambientGenerics !== undefined ? this.sql.json(asJson(sc.ambientGenerics)) : null})
        ON CONFLICT (project_id, id) DO UPDATE
          SET owner_entity_id = EXCLUDED.owner_entity_id,
              parent_id = EXCLUDED.parent_id,
              values = EXCLUDED.values,
              ambient_generics = EXCLUDED.ambient_generics
      `;
    }
    for (const c of closures) {
      await this.sql`
        INSERT INTO closures (project_id, id, owner_entity_id, block_id, captured_scope_id, snapshot)
        VALUES (${projectId}, ${c.id}, ${c.owner}, ${c.blockId}, ${c.scopeId}, ${c.snapshot})
        ON CONFLICT (project_id, id) DO UPDATE
          SET owner_entity_id = EXCLUDED.owner_entity_id,
              block_id = EXCLUDED.block_id,
              captured_scope_id = EXCLUDED.captured_scope_id,
              snapshot = EXCLUDED.snapshot
      `;
    }
  }

  async deleteOwned(projectId: string, entity: EntityId): Promise<void> {
    await this
      .sql`DELETE FROM scopes   WHERE project_id = ${projectId} AND owner_entity_id = ${entity}`;
    await this
      .sql`DELETE FROM closures WHERE project_id = ${projectId} AND owner_entity_id = ${entity}`;
  }

  async loadOwned(
    projectId: string,
    entity: EntityId,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }> {
    const scopeRows = await this.sql<ScopeRow[]>`
      SELECT id, owner_entity_id, parent_id, values, ambient_generics
      FROM scopes WHERE project_id = ${projectId} AND owner_entity_id = ${entity}
    `;
    const closureRows = await this.sql<ClosureRow[]>`
      SELECT id, owner_entity_id, block_id, captured_scope_id, snapshot
      FROM closures WHERE project_id = ${projectId} AND owner_entity_id = ${entity}
    `;
    return { scopes: scopeRows.map(toScope), closures: closureRows.map(toClosure) };
  }

  async loadByIds(
    projectId: string,
    scopeIds: ReadonlyArray<ScopeId>,
    closureIds: ReadonlyArray<ClosureId>,
  ): Promise<{ scopes: PersistedScope[]; closures: PersistedClosure[] }> {
    const scopeRows =
      scopeIds.length === 0
        ? []
        : await this.sql<ScopeRow[]>`
            SELECT id, owner_entity_id, parent_id, values, ambient_generics
            FROM scopes WHERE project_id = ${projectId} AND id IN ${this.sql([...scopeIds] as string[])}
          `;
    const closureRows =
      closureIds.length === 0
        ? []
        : await this.sql<ClosureRow[]>`
            SELECT id, owner_entity_id, block_id, captured_scope_id, snapshot
            FROM closures WHERE project_id = ${projectId} AND id IN ${this.sql([...closureIds] as string[])}
          `;
    return { scopes: scopeRows.map(toScope), closures: closureRows.map(toClosure) };
  }

  async sweepDetached(projectId: string): Promise<void> {
    await this
      .sql`DELETE FROM scopes   WHERE project_id = ${projectId} AND owner_entity_id IS NULL`;
    await this
      .sql`DELETE FROM closures WHERE project_id = ${projectId} AND owner_entity_id IS NULL`;
  }
}
