// Project-root entity helper.
//
// The project-root entity (docs/2026-06-01-entity-model.md) is the one entity
// summoned by nobody (`delegation_id = null`, `module = api`): it owns the
// project's user uploads and is kept for the project's life. Its id is
// deterministically the project id, so it needs no lookup table and any caller
// can ensure / address it.

import type { EntityId, ProjectId, Storage } from "./storage/types.js";

/** Get-or-create the project-root entity (`id = projectId`). Idempotent. */
export async function ensureProjectRootEntity(
  tx: Storage,
  projectId: ProjectId,
): Promise<EntityId> {
  const id = projectId as unknown as EntityId;
  const existing = await tx.entities.get(id);
  if (existing !== null) return id;
  const now = new Date().toISOString();
  await tx.entities.insert({
    id,
    delegationId: null,
    projectId,
    module: "api",
    state: "running",
    agentDefId: null,
    args: {},
    createdAt: now,
    updatedAt: now,
  });
  return id;
}
