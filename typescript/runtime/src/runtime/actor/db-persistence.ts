// Drizzle-backed persistence: commit one turn atomically each turn boundary, load a project's graph on
// reactivation. A commit writes the turn's Layer 2 (instances + threads + scopes — or the instance's drop)
// together with the Layer 1 entity transitions it implies (delegations / escalations), in a single
// transaction, so an edge's durable row never lags the engine threads that reference it. Loading returns
// the engine graph plus the live (running / cancelling) delegation edges the actor routes by.

import { and, eq, inArray, isNotNull } from "drizzle-orm";
import type { Database } from "../../db/client.js";
import { scopes, threads } from "../../db/tables/engine.js";
import { delegations, escalations, instances } from "../../db/tables/execution.js";
import type { DelegationId, EscalationId, InstanceId, ProjectId } from "../ids.js";
import type { Persistence, ProjectSnapshot } from "./persistence.js";
import {
  deserializeProject,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
  serializeInstance,
} from "./persistence-codec.js";
import type { TurnCommit } from "./turn-commit.js";

export class DbPersistence implements Persistence {
  constructor(private readonly db: Database) {}

  async loadProject(projectId: ProjectId): Promise<ProjectSnapshot> {
    const [instanceRows, threadRows, scopeRows, delegationRows, escalationRows] = await Promise.all(
      [
        this.db
          .select()
          .from(instances)
          .where(and(eq(instances.projectId, projectId), isNotNull(instances.engineState))),
        this.db.select().from(threads).where(eq(threads.projectId, projectId)),
        this.db.select().from(scopes).where(eq(scopes.projectId, projectId)),
        // Only live edges carry routing; finished ones (done / gone) are history.
        this.db
          .select()
          .from(delegations)
          .where(
            and(
              eq(delegations.projectId, projectId),
              inArray(delegations.state, ["running", "cancelling"]),
            ),
          ),
        this.db
          .select()
          .from(escalations)
          .where(and(eq(escalations.projectId, projectId), eq(escalations.state, "open"))),
      ],
    );
    const persistedInstances: PersistedInstance[] = instanceRows.flatMap((row) =>
      row.engineState === null
        ? []
        : [
            {
              id: row.id as InstanceId,
              projectId: row.projectId as ProjectId,
              kind: row.kind,
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
    const engine = deserializeProject(persistedInstances, persistedThreads, persistedScopes);
    const liveDelegations: Record<DelegationId, InstanceId> = {};
    for (const row of delegationRows) {
      if (row.callerInstanceId !== null) {
        liveDelegations[row.id as DelegationId] = row.callerInstanceId as InstanceId;
      }
    }
    const openEscalations: ProjectSnapshot["openEscalations"] = escalationRows.map((row) => ({
      escalation: row.id as EscalationId,
      raiser: row.raiserInstanceId as InstanceId,
      request: row.request,
      argument: row.argument,
    }));
    return { ...engine, delegations: liveDelegations, openEscalations };
  }

  async commitTurn(projectId: ProjectId, commit: TurnCommit): Promise<void> {
    await this.db.transaction(async (tx) => {
      // FK ordering: open a delegation *before* the child instance that references it; open an escalation
      // *after* its raiser instance exists; apply state updates last (they touch existing rows only).
      for (const transition of commit.transitions) {
        if (transition.kind !== "delegation-open") continue;
        await tx
          .insert(delegations)
          .values({
            id: transition.delegation,
            projectId,
            callerInstanceId: transition.caller,
            target: transition.target,
            argument: transition.argument,
            state: "running",
          })
          .onConflictDoNothing();
      }

      if (commit.layer2.kind === "drop") {
        // Cascade removes the instance's threads / scopes / owned delegations + escalations.
        await tx
          .delete(instances)
          .where(and(eq(instances.projectId, projectId), eq(instances.id, commit.instanceId)));
      } else {
        const serialized = serializeInstance(
          projectId,
          commit.layer2.instance,
          commit.layer2.ownedScopes,
        );
        await tx
          .insert(instances)
          .values({
            id: serialized.instance.id,
            projectId,
            kind: serialized.instance.kind,
            delegationId: serialized.instance.delegationId,
            target: serialized.instance.target,
            snapshotId: serialized.instance.snapshotId,
            status: serialized.instance.status,
            ambientGenerics: serialized.instance.ambientGenerics ?? undefined,
            engineState: serialized.instance.engineState ?? undefined,
          })
          .onConflictDoUpdate({
            target: instances.id,
            set: {
              status: serialized.instance.status,
              engineState: serialized.instance.engineState ?? undefined,
              ambientGenerics: serialized.instance.ambientGenerics ?? undefined,
            },
          });
        // Replace the instance's thread + owned-scope rows wholesale (the trees are small).
        const instanceId = serialized.instance.id;
        await tx
          .delete(threads)
          .where(and(eq(threads.projectId, projectId), eq(threads.instanceId, instanceId)));
        if (serialized.threads.length > 0) await tx.insert(threads).values(serialized.threads);
        await tx
          .delete(scopes)
          .where(and(eq(scopes.projectId, projectId), eq(scopes.ownerInstanceId, instanceId)));
        if (serialized.scopes.length > 0) await tx.insert(scopes).values(serialized.scopes);
      }

      // Edge state updates (and escalation opens, which need their raiser instance to exist). No-ops if the
      // row was already cascade-removed (e.g. a delegation whose caller dropped this same turn).
      for (const transition of commit.transitions) {
        switch (transition.kind) {
          case "delegation-done":
            await tx
              .update(delegations)
              .set({ state: "done", result: transition.result })
              .where(
                and(
                  eq(delegations.projectId, projectId),
                  eq(delegations.id, transition.delegation),
                ),
              );
            break;
          case "delegation-cancelling":
            await tx
              .update(delegations)
              .set({ state: "cancelling" })
              .where(
                and(
                  eq(delegations.projectId, projectId),
                  eq(delegations.id, transition.delegation),
                ),
              );
            break;
          case "delegation-gone":
            await tx
              .update(delegations)
              .set({ state: "gone" })
              .where(
                and(
                  eq(delegations.projectId, projectId),
                  eq(delegations.id, transition.delegation),
                ),
              );
            break;
          case "escalation-open":
            await tx
              .insert(escalations)
              .values({
                id: transition.escalation,
                projectId,
                raiserInstanceId: transition.raiser,
                request: transition.request,
                argument: transition.argument,
                state: "open",
              })
              .onConflictDoNothing();
            break;
          case "escalation-answered":
            await tx
              .update(escalations)
              .set({ state: "answered", answer: transition.answer })
              .where(
                and(
                  eq(escalations.projectId, projectId),
                  eq(escalations.id, transition.escalation),
                ),
              );
            break;
        }
      }
    });
  }
}
