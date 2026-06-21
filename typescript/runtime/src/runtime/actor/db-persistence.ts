// Drizzle-backed persistence: write-through an instance's graph each turn, load a project's graph on
// reactivation. Three row sets — instances (with engine_state), threads, scopes — suffice; the actor
// derives its routing maps from them. Each instance's persist is one transaction that replaces its
// thread + owned-scope rows wholesale (the trees are small), keeping it the single source of truth.

import { and, eq, isNotNull } from "drizzle-orm";
import type { Database } from "../../db/client.js";
import { scopes, threads } from "../../db/tables/engine.js";
import { instances } from "../../db/tables/execution.js";
import type { Instance, Scope } from "../engine/types.js";
import type { InstanceId, ProjectId } from "../ids.js";
import type { Persistence, ProjectSnapshot } from "./persistence.js";
import {
  deserializeProject,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
  serializeInstance,
} from "./persistence-codec.js";

export class DbPersistence implements Persistence {
  constructor(private readonly db: Database) {}

  async loadProject(projectId: ProjectId): Promise<ProjectSnapshot> {
    const [instanceRows, threadRows, scopeRows] = await Promise.all([
      this.db
        .select()
        .from(instances)
        .where(and(eq(instances.projectId, projectId), isNotNull(instances.engineState))),
      this.db.select().from(threads).where(eq(threads.projectId, projectId)),
      this.db.select().from(scopes).where(eq(scopes.projectId, projectId)),
    ]);
    const persistedInstances: PersistedInstance[] = instanceRows.flatMap((row) =>
      row.engineState === null
        ? []
        : [
            {
              id: row.id as InstanceId,
              projectId: row.projectId as ProjectId,
              delegationId: row.delegationId as PersistedInstance["delegationId"],
              target: row.target,
              snapshotId: row.snapshotId as PersistedInstance["snapshotId"],
              status: row.status,
              ambientGenerics: row.ambientGenerics ?? null,
              engineState: row.engineState,
            },
          ],
    );
    const persistedThreads: PersistedThread[] = threadRows.map((row) => ({
      projectId: row.projectId as ProjectId,
      instanceId: row.instanceId as InstanceId,
      threadId: row.threadId,
      kind: row.kind,
      parentThreadId: row.parentThreadId,
      parentCallId: row.parentCallId,
      scopeId: row.scopeId,
      blockId: row.blockId,
      status: row.status,
      payload: row.payload,
    }));
    const persistedScopes: PersistedScope[] = scopeRows.map((row) => ({
      projectId: row.projectId as ProjectId,
      scopeId: row.scopeId,
      parentScopeId: row.parentScopeId,
      ownerInstanceId: row.ownerInstanceId as InstanceId | null,
      values: row.values,
    }));
    return deserializeProject(persistedInstances, persistedThreads, persistedScopes);
  }

  async persistInstance(
    projectId: ProjectId,
    instance: Instance,
    ownedScopes: Scope[],
  ): Promise<void> {
    const serialized = serializeInstance(projectId, instance, ownedScopes);
    await this.db.transaction(async (tx) => {
      await tx
        .insert(instances)
        .values({
          id: serialized.instance.id,
          projectId,
          delegationId: serialized.instance.delegationId,
          target: serialized.instance.target,
          snapshotId: serialized.instance.snapshotId,
          status: serialized.instance.status,
          ambientGenerics: serialized.instance.ambientGenerics ?? undefined,
          engineState: serialized.instance.engineState,
        })
        .onConflictDoUpdate({
          target: instances.id,
          set: {
            status: serialized.instance.status,
            engineState: serialized.instance.engineState,
            ambientGenerics: serialized.instance.ambientGenerics ?? undefined,
          },
        });
      // Replace the instance's thread + owned-scope rows wholesale (the trees are small).
      await tx
        .delete(threads)
        .where(and(eq(threads.projectId, projectId), eq(threads.instanceId, instance.id)));
      if (serialized.threads.length > 0) {
        await tx.insert(threads).values(serialized.threads);
      }
      await tx
        .delete(scopes)
        .where(and(eq(scopes.projectId, projectId), eq(scopes.ownerInstanceId, instance.id)));
      if (serialized.scopes.length > 0) {
        await tx.insert(scopes).values(serialized.scopes);
      }
    });
  }

  async dropInstance(projectId: ProjectId, instanceId: InstanceId): Promise<void> {
    // Cascade removes the instance's threads / scopes / delegations / escalations.
    await this.db
      .delete(instances)
      .where(and(eq(instances.projectId, projectId), eq(instances.id, instanceId)));
  }
}
