// Drizzle-backed persistence: the shared turn-commit logic (`row-store.ts`) over a `RowStore` whose every
// method is one SQL statement. One turn = one DB transaction (the store is constructed over the open
// transaction handle), so an edge's durable row can never lag the engine threads that reference it; the
// cascade on an instance drop is delegated to the tables' ON DELETE CASCADE. Reads run outside any
// transaction: reactivation happens before any commit on a serial actor, so separate selects see a
// consistent snapshot.

import { and, asc, eq } from "drizzle-orm";
import type { Database, Executor } from "../../db/client.js";
import { blobs, scopes, threads } from "../../db/tables/engine.js";
import {
  capabilityRoutes,
  coreInstances,
  delegations,
  escalations,
  externalCallInstances,
  instances,
  outbox,
  runEscalationsAudit,
  runEvents,
  runs,
} from "../../db/tables/execution.js";
import type {
  BlobId,
  DelegationId,
  EscalationId,
  InstanceId,
  OutboxSeq,
  ProjectId,
  SnapshotId,
} from "../ids.js";
import type { Loader, Persistence, PersistenceTx } from "./persistence.js";
import type { PersistedBlob, PersistedScope, PersistedThread } from "./persistence-codec.js";
import { type RowStore, storeLoader, storeTx } from "./row-store.js";

export class DbPersistence implements Persistence {
  constructor(private readonly db: Database) {}

  async load(projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    await body(storeLoader(new DrizzleRowStore(this.db, projectId)));
  }

  async transaction(
    projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    await this.db.transaction(async (drizzleTx) => {
      await body(storeTx(new DrizzleRowStore(drizzleTx, projectId)));
    });
  }
}

/** The SQL row CRUD, one statement per method, project-scoped by construction. Payloads arrive already
 *  sealed (and leave still sealed) — the shared logic above owns the seal boundary. */
class DrizzleRowStore implements RowStore {
  constructor(
    private readonly executor: Executor,
    private readonly projectId: ProjectId,
  ) {}

  async putInstance(row: Parameters<RowStore["putInstance"]>[0]): Promise<void> {
    await this.executor
      .insert(instances)
      .values({
        id: row.id,
        projectId: this.projectId,
        kind: row.kind,
        delegationId: row.delegationId,
        callerReactor: row.callerReactor,
        runId: row.runId,
        status: row.status,
      })
      // `caller_reactor` / `run_id` are immutable (the summoner and the run never change), so only
      // `status` is updated on re-upsert.
      .onConflictDoUpdate({ target: instances.id, set: { status: row.status } });
  }

  async deleteInstance(id: InstanceId): Promise<void> {
    // The FK cascade removes the instance's extension / threads / owned scopes / owned delegations +
    // escalations / capability routes. A scope its result released to in-transit (`owner = null`) is not
    // owned by it, so it survives; the pool re-writes it in this same commit (after this drop) with its
    // new owner.
    await this.executor
      .delete(instances)
      .where(and(eq(instances.projectId, this.projectId), eq(instances.id, id)));
  }

  async putDelegation(row: Parameters<RowStore["putDelegation"]>[0]): Promise<void> {
    await this.executor
      .insert(delegations)
      .values({
        id: row.delegation,
        projectId: this.projectId,
        callerInstanceId: row.caller,
        fromReactor: row.fromReactor,
        toReactor: row.toReactor,
        state: row.state,
      })
      // The only mutable field is `state` (running → cancelling); everything else is immutable at open.
      .onConflictDoUpdate({ target: delegations.id, set: { state: row.state } });
  }

  async deleteDelegation(id: DelegationId): Promise<void> {
    await this.executor
      .delete(delegations)
      .where(and(eq(delegations.projectId, this.projectId), eq(delegations.id, id)));
  }

  async insertEscalation(row: Parameters<RowStore["insertEscalation"]>[0]): Promise<void> {
    await this.executor
      .insert(escalations)
      .values({
        id: row.escalation,
        projectId: this.projectId,
        raiserInstanceId: row.raiser,
        fromReactor: row.fromReactor,
        toReactor: row.toReactor,
        delegationId: row.delegation,
        runId: row.run,
        request: row.request,
        argument: row.argument,
      })
      .onConflictDoNothing();
  }

  async deleteEscalation(id: EscalationId): Promise<void> {
    await this.executor
      .delete(escalations)
      .where(and(eq(escalations.projectId, this.projectId), eq(escalations.id, id)));
  }

  async putCore(row: Parameters<RowStore["putCore"]>[0]): Promise<void> {
    await this.executor
      .insert(coreInstances)
      .values({
        instanceId: row.instanceId,
        target: row.target,
        snapshotId: row.snapshotId,
        ambientGenerics: row.ambientGenerics ?? undefined,
        engineState: row.engineState,
      })
      .onConflictDoUpdate({
        target: coreInstances.instanceId,
        set: { engineState: row.engineState, ambientGenerics: row.ambientGenerics ?? undefined },
      });
  }

  async replaceThreads(instance: InstanceId, rows: PersistedThread[]): Promise<void> {
    await this.executor
      .delete(threads)
      .where(and(eq(threads.projectId, this.projectId), eq(threads.instanceId, instance)));
    if (rows.length > 0) await this.executor.insert(threads).values(rows);
  }

  async putExternalCall(row: Parameters<RowStore["putExternalCall"]>[0]): Promise<void> {
    await this.executor
      .insert(externalCallInstances)
      .values(row)
      .onConflictDoUpdate({
        target: externalCallInstances.instanceId,
        set: { status: row.status, extension: row.extension },
      });
  }

  async putRoute(route: Parameters<RowStore["putRoute"]>[0]): Promise<void> {
    await this.executor
      .insert(capabilityRoutes)
      .values({ token: route.token, projectId: this.projectId, instanceId: route.instance })
      .onConflictDoNothing();
  }

  async putScope(row: PersistedScope): Promise<void> {
    await this.executor
      .insert(scopes)
      .values({
        projectId: this.projectId,
        scopeId: row.scopeId,
        parentScopeId: row.parentScopeId,
        ownerInstanceId: row.ownerInstanceId,
        values: row.values,
      })
      .onConflictDoUpdate({
        target: [scopes.projectId, scopes.scopeId],
        set: {
          parentScopeId: row.parentScopeId,
          ownerInstanceId: row.ownerInstanceId,
          values: row.values,
        },
      });
  }

  async deleteScope(scopeId: number): Promise<void> {
    await this.executor
      .delete(scopes)
      .where(and(eq(scopes.projectId, this.projectId), eq(scopes.scopeId, scopeId)));
  }

  async putBlob(row: PersistedBlob): Promise<void> {
    await this.executor
      .insert(blobs)
      .values({
        projectId: this.projectId,
        blobId: row.blobId,
        ownerInstanceId: row.ownerInstanceId,
        hash: row.hash,
        size: row.size,
        contentType: row.contentType,
        semanticKind: row.semanticKind,
      })
      .onConflictDoUpdate({
        target: [blobs.projectId, blobs.blobId],
        set: { ownerInstanceId: row.ownerInstanceId },
      });
  }

  async deleteBlob(id: BlobId): Promise<void> {
    await this.executor
      .delete(blobs)
      .where(and(eq(blobs.projectId, this.projectId), eq(blobs.blobId, id)));
  }

  async insertRun(row: Parameters<RowStore["insertRun"]>[0]): Promise<void> {
    await this.executor
      .insert(runs)
      .values({
        id: row.run,
        projectId: this.projectId,
        snapshotId: row.snapshotId,
        name: row.name,
        qualifiedName: row.qualifiedName,
        argument: row.argument,
      })
      .onConflictDoNothing();
  }

  async updateRun(run: InstanceId, patch: Parameters<RowStore["updateRun"]>[1]): Promise<void> {
    await this.executor
      .update(runs)
      .set({
        state: patch.state,
        result: patch.result,
        errorMessage: patch.errorMessage,
        ...(patch.completedAt !== undefined ? { completedAt: patch.completedAt } : {}),
        ...(patch.cancelReason !== undefined ? { cancelReason: patch.cancelReason } : {}),
      })
      .where(and(eq(runs.projectId, this.projectId), eq(runs.id, run)));
  }

  async insertAudit(row: Parameters<RowStore["insertAudit"]>[0]): Promise<void> {
    await this.executor
      .insert(runEscalationsAudit)
      .values({
        runId: row.run,
        escalationId: row.escalation,
        question: row.question,
        answer: row.answer,
      })
      .onConflictDoNothing();
  }

  async deleteOutbox(seq: OutboxSeq): Promise<void> {
    await this.executor.delete(outbox).where(eq(outbox.seq, seq));
  }

  async insertOutbox(rows: Parameters<RowStore["insertOutbox"]>[0]): Promise<void> {
    if (rows.length === 0) return;
    await this.executor
      .insert(outbox)
      .values(rows.map((row) => ({ seq: row.seq, projectId: this.projectId, event: row.event })));
  }

  async appendJournal(events: Parameters<RowStore["appendJournal"]>[0]): Promise<void> {
    if (events.length === 0) return;
    // A multi-row insert assigns the `seq` bigserial in row order, so the array's (causal production)
    // order is the journal order.
    await this.executor
      .insert(runEvents)
      .values(events.map((event) => ({ projectId: this.projectId, runId: event.run, event })));
  }

  async delegationsFrom(
    from: Parameters<RowStore["delegationsFrom"]>[0],
  ): ReturnType<RowStore["delegationsFrom"]> {
    const rows = await this.executor
      .select({
        id: delegations.id,
        callerInstanceId: delegations.callerInstanceId,
        fromReactor: delegations.fromReactor,
        toReactor: delegations.toReactor,
        state: delegations.state,
      })
      .from(delegations)
      .where(and(eq(delegations.projectId, this.projectId), eq(delegations.fromReactor, from)));
    // The caller column is nullable only for the FK's sake; a row whose caller was nulled has no owner
    // left to reload it, so it is not a loadable delegation.
    return rows.flatMap((row) =>
      row.callerInstanceId === null
        ? []
        : [
            {
              delegation: row.id as DelegationId,
              caller: row.callerInstanceId as InstanceId,
              fromReactor: row.fromReactor,
              toReactor: row.toReactor,
              state: row.state,
            },
          ],
    );
  }

  async openEscalations(
    filter: Parameters<RowStore["openEscalations"]>[0],
  ): ReturnType<RowStore["openEscalations"]> {
    const conditions = [eq(escalations.projectId, this.projectId)];
    if (filter.from !== undefined) conditions.push(eq(escalations.fromReactor, filter.from));
    if (filter.to !== undefined) conditions.push(eq(escalations.toReactor, filter.to));
    const rows = await this.executor
      .select()
      .from(escalations)
      .where(and(...conditions));
    return rows.map((row) => ({
      escalation: row.id as EscalationId,
      raiser: row.raiserInstanceId as InstanceId,
      fromReactor: row.fromReactor,
      toReactor: row.toReactor,
      delegation: row.delegationId as DelegationId,
      run: row.runId as InstanceId,
      request: row.request,
      argument: row.argument,
    }));
  }

  async coreInstances(): ReturnType<RowStore["coreInstances"]> {
    const rows = await this.executor
      .select({
        id: instances.id,
        delegationId: instances.delegationId,
        callerReactor: instances.callerReactor,
        runId: instances.runId,
        status: instances.status,
        target: coreInstances.target,
        snapshotId: coreInstances.snapshotId,
        ambientGenerics: coreInstances.ambientGenerics,
        engineState: coreInstances.engineState,
      })
      .from(instances)
      .innerJoin(coreInstances, eq(instances.id, coreInstances.instanceId))
      .where(and(eq(instances.projectId, this.projectId), eq(instances.kind, "core")));
    return rows.map((row) => ({
      id: row.id as InstanceId,
      delegationId: row.delegationId as DelegationId | null,
      callerReactor: row.callerReactor,
      runId: row.runId as InstanceId | null,
      status: row.status,
      core: {
        instanceId: row.id as InstanceId,
        target: row.target,
        snapshotId: row.snapshotId as SnapshotId,
        ambientGenerics: row.ambientGenerics ?? null,
        engineState: row.engineState,
      },
    }));
  }

  async threads(): Promise<PersistedThread[]> {
    const rows = await this.executor
      .select()
      .from(threads)
      .where(eq(threads.projectId, this.projectId));
    return rows.map((row) => ({
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
  }

  async scopes(): Promise<PersistedScope[]> {
    const rows = await this.executor
      .select()
      .from(scopes)
      .where(eq(scopes.projectId, this.projectId));
    return rows.map((row) => ({
      projectId: row.projectId as ProjectId,
      scopeId: row.scopeId,
      parentScopeId: row.parentScopeId,
      ownerInstanceId: row.ownerInstanceId as InstanceId | null,
      values: row.values,
    }));
  }

  async blobs(): Promise<PersistedBlob[]> {
    const rows = await this.executor
      .select()
      .from(blobs)
      .where(eq(blobs.projectId, this.projectId));
    return rows.map((row) => ({
      projectId: row.projectId as ProjectId,
      blobId: row.blobId as BlobId,
      ownerInstanceId: row.ownerInstanceId as InstanceId | null,
      hash: row.hash,
      size: row.size,
      contentType: row.contentType,
      semanticKind: row.semanticKind,
    }));
  }

  async externalCalls(
    kind: Parameters<RowStore["externalCalls"]>[0],
  ): ReturnType<RowStore["externalCalls"]> {
    const rows = await this.executor
      .select({
        instance: instances.id,
        delegation: instances.delegationId,
        caller: instances.callerReactor,
        run: instances.runId,
        status: externalCallInstances.status,
        extension: externalCallInstances.extension,
      })
      .from(instances)
      .innerJoin(externalCallInstances, eq(instances.id, externalCallInstances.instanceId))
      .where(and(eq(instances.projectId, this.projectId), eq(instances.kind, kind)));
    return rows.map((row) => ({
      instance: row.instance as InstanceId,
      delegation: row.delegation as DelegationId | null,
      caller: row.caller,
      run: row.run as InstanceId | null,
      status: row.status,
      extension: row.extension,
    }));
  }

  async pendingOutbox(): ReturnType<RowStore["pendingOutbox"]> {
    // In production order (routing recovers from the engine threads, so replay order only needs to be
    // stable, not strictly causal).
    const rows = await this.executor
      .select()
      .from(outbox)
      .where(eq(outbox.projectId, this.projectId))
      .orderBy(asc(outbox.createdAt));
    return rows.map((row) => ({ seq: row.seq as OutboxSeq, event: row.event }));
  }
}
