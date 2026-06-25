// Drizzle-backed persistence: one turn = one `transaction`, in which the reacting reactor writes its own
// state through a `PersistenceTx` and the substrate writes the transactional outbox. A delegation row is
// upserted by its caller, an escalation by its raiser, a still-running instance's Layer 2 (instance row +
// thread tree) is replaced wholesale, scopes are upserted independently by the `ResourcePool` (`putScope`),
// and a completed instance is dropped (cascade). Writing all of it in a single DB transaction is what keeps
// an edge's durable row from lagging the engine threads that reference it. Loading returns the engine graph
// plus the live (running / cancelling) delegation rows and open escalations each reactor reloads as its own.

import { and, asc, eq, inArray, isNotNull } from "drizzle-orm";
import type { Database } from "../../db/client.js";
import { blobs, scopes, threads } from "../../db/tables/engine.js";
import {
  delegations,
  escalations,
  ffiCalls,
  instances,
  LIVE_DELEGATION_STATES,
  outbox,
  runEscalationsAudit,
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
import {
  deserializeProject,
  type PersistedBlob,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
} from "./persistence-codec.js";

export class DbPersistence implements Persistence {
  constructor(private readonly db: Database) {}

  async load(projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    await body(this.loader(projectId));
  }

  /** The per-reactor read surface: each method runs one query, self-selecting by reactor. Reactivation runs
   *  before any commit on a serial actor, so separate reads see a consistent snapshot without a read tx. */
  private loader(projectId: ProjectId): Loader {
    return {
      engine: async () => {
        const [instanceRows, threadRows, scopeRows, blobRows] = await Promise.all([
          this.db
            .select()
            .from(instances)
            .where(and(eq(instances.projectId, projectId), isNotNull(instances.engineState))),
          this.db.select().from(threads).where(eq(threads.projectId, projectId)),
          this.db.select().from(scopes).where(eq(scopes.projectId, projectId)),
          this.db.select().from(blobs).where(eq(blobs.projectId, projectId)),
        ]);
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
        const persistedBlobs: PersistedBlob[] = blobRows.map((row) => ({
          projectId: row.projectId as ProjectId,
          blobId: row.blobId as BlobId,
          ownerInstanceId: row.ownerInstanceId as InstanceId | null,
          hash: row.hash,
          size: row.size,
          contentType: row.contentType,
          semanticKind: row.semanticKind,
        }));
        return deserializeProject(
          persistedInstances,
          persistedThreads,
          persistedScopes,
          persistedBlobs,
        );
      },
      delegations: async (from) => {
        // Only live rows carry routing; finished ones (done / gone / failed) are history.
        const rows = await this.db
          .select()
          .from(delegations)
          .where(
            and(
              eq(delegations.projectId, projectId),
              eq(delegations.fromReactor, from),
              inArray(delegations.state, LIVE_DELEGATION_STATES),
            ),
          );
        return rows.flatMap((row) =>
          row.callerInstanceId === null
            ? []
            : [
                {
                  delegation: row.id as DelegationId,
                  caller: row.callerInstanceId as InstanceId,
                  fromReactor: row.fromReactor,
                  toReactor: row.toReactor,
                  target: row.target,
                  argument: row.argument,
                  state: row.state,
                  result: row.result,
                  errorMessage: row.errorMessage,
                },
              ],
        );
      },
      openEscalations: async (filter) => {
        const conditions = [
          eq(escalations.projectId, projectId),
          eq(escalations.state, "open" as const),
        ];
        if (filter.from !== undefined) conditions.push(eq(escalations.fromReactor, filter.from));
        if (filter.to !== undefined) conditions.push(eq(escalations.toReactor, filter.to));
        const rows = await this.db
          .select()
          .from(escalations)
          .where(and(...conditions));
        return rows.map((row) => ({
          escalation: row.id as EscalationId,
          raiser: row.raiserInstanceId as InstanceId,
          fromReactor: row.fromReactor,
          toReactor: row.toReactor,
          delegation: row.delegationId as DelegationId,
          request: row.request,
          argument: row.argument,
        }));
      },
      outbox: async () => {
        // In production order (routing recovers from the engine threads, so replay order only needs to be
        // stable, not strictly causal).
        const rows = await this.db
          .select()
          .from(outbox)
          .where(eq(outbox.projectId, projectId))
          .orderBy(asc(outbox.createdAt));
        return rows.map((row) => ({
          seq: row.seq as OutboxSeq,
          issuer: row.instanceId as InstanceId,
          event: row.event,
        }));
      },
      ffiCalls: async () => {
        const rows = await this.db.select().from(ffiCalls).where(eq(ffiCalls.projectId, projectId));
        return rows.map((row) => ({
          delegation: row.delegation as DelegationId,
          instance: row.instanceId as InstanceId,
          snapshot: row.snapshotId as SnapshotId,
          key: row.key,
          argument: row.argument,
          caller: row.callerReactor,
          status: row.status,
        }));
      },
    };
  }

  async transaction(
    projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    await this.db.transaction(async (drizzleTx) => {
      await body(this.tx(drizzleTx, projectId));
    });
  }

  /** The per-turn write surface over one DB transaction. Each method issues a single statement; FK ordering
   *  (instance before the rows that reference it, cascade drop last) is the reactor's call order. */
  private tx(
    drizzleTx: Parameters<Parameters<Database["transaction"]>[0]>[0],
    projectId: ProjectId,
  ): PersistenceTx {
    return {
      putDelegation: async (row) => {
        await drizzleTx
          .insert(delegations)
          .values({
            id: row.delegation,
            projectId,
            callerInstanceId: row.caller,
            fromReactor: row.fromReactor,
            toReactor: row.toReactor,
            target: row.target,
            argument: row.argument,
            state: row.state,
            result: row.result,
            errorMessage: row.errorMessage,
          })
          .onConflictDoUpdate({
            target: delegations.id,
            set: { state: row.state, result: row.result, errorMessage: row.errorMessage },
          });
      },
      putEscalation: async (row) => {
        await drizzleTx
          .insert(escalations)
          .values({
            id: row.escalation,
            projectId,
            raiserInstanceId: row.raiser,
            fromReactor: row.fromReactor,
            toReactor: row.toReactor,
            delegationId: row.delegation,
            request: row.request,
            argument: row.argument,
            state: row.state,
            answer: row.answer,
          })
          .onConflictDoUpdate({
            target: escalations.id,
            set: { state: row.state, answer: row.answer },
          });
      },
      putInstance: async (serialized) => {
        const instance = serialized.instance;
        await drizzleTx
          .insert(instances)
          .values({
            id: instance.id,
            projectId,
            kind: instance.kind,
            target: instance.target,
            snapshotId: instance.snapshotId,
            status: instance.status,
            ambientGenerics: instance.ambientGenerics ?? undefined,
            engineState: instance.engineState ?? undefined,
            delegationId: instance.delegationId,
          })
          .onConflictDoUpdate({
            target: instances.id,
            set: {
              status: instance.status,
              engineState: instance.engineState ?? undefined,
              ambientGenerics: instance.ambientGenerics ?? undefined,
            },
          });
        // Replace the instance's thread rows wholesale (the trees are small). Scopes are NOT here — they
        // persist independently through `putScope`.
        await drizzleTx
          .delete(threads)
          .where(and(eq(threads.projectId, projectId), eq(threads.instanceId, instance.id)));
        if (serialized.threads.length > 0)
          await drizzleTx.insert(threads).values(serialized.threads);
      },
      putScope: async (scope) => {
        await drizzleTx
          .insert(scopes)
          .values({
            projectId,
            scopeId: scope.scopeId,
            parentScopeId: scope.parentScopeId,
            ownerInstanceId: scope.ownerInstanceId,
            values: scope.values,
          })
          .onConflictDoUpdate({
            target: [scopes.projectId, scopes.scopeId],
            set: {
              parentScopeId: scope.parentScopeId,
              ownerInstanceId: scope.ownerInstanceId,
              values: scope.values,
            },
          });
      },
      deleteScope: async (scopeId) => {
        await drizzleTx
          .delete(scopes)
          .where(and(eq(scopes.projectId, projectId), eq(scopes.scopeId, scopeId)));
      },
      putBlob: async (blob) => {
        await drizzleTx
          .insert(blobs)
          .values({
            projectId,
            blobId: blob.blobId,
            ownerInstanceId: blob.ownerInstanceId,
            hash: blob.hash,
            size: blob.size,
            contentType: blob.contentType,
            semanticKind: blob.semanticKind,
          })
          .onConflictDoUpdate({
            target: [blobs.projectId, blobs.blobId],
            set: { ownerInstanceId: blob.ownerInstanceId },
          });
      },
      dropBlob: async (blobId) => {
        await drizzleTx
          .delete(blobs)
          .where(and(eq(blobs.projectId, projectId), eq(blobs.blobId, blobId)));
      },
      dropInstance: async (instanceId) => {
        // Cascade removes the instance's threads / the scopes it still owns / owned delegations + escalations.
        // A scope its result released to in-transit (`owner = null`) is not owned by it, so it survives; the
        // pool re-writes it in this same commit (after this drop) with its new owner.
        await drizzleTx
          .delete(instances)
          .where(and(eq(instances.projectId, projectId), eq(instances.id, instanceId)));
      },
      consumeOutbox: async (seq) => {
        await drizzleTx.delete(outbox).where(eq(outbox.seq, seq));
      },
      produceOutbox: async (messages) => {
        if (messages.length === 0) return;
        await drizzleTx.insert(outbox).values(
          messages.map((message) => ({
            seq: message.seq,
            projectId,
            instanceId: message.issuer,
            event: message.event,
          })),
        );
      },
      putRun: async (run) => {
        await drizzleTx
          .insert(runs)
          .values({
            id: run.run,
            projectId,
            snapshotId: run.snapshotId,
            name: run.name,
            qualifiedName: run.qualifiedName,
            argument: run.argument,
          })
          .onConflictDoNothing();
      },
      setRunCancelReason: async (run, reason) => {
        await drizzleTx
          .update(runs)
          .set({ cancelReason: reason })
          .where(and(eq(runs.projectId, projectId), eq(runs.id, run)));
      },
      putRunEscalationAudit: async (audit) => {
        await drizzleTx
          .insert(runEscalationsAudit)
          .values({
            runId: audit.run,
            escalationId: audit.escalation,
            question: audit.question,
            answer: audit.answer,
          })
          .onConflictDoNothing();
      },
      ensureApiRoot: async (apiRootId) => {
        // The api root runs no IR (no target / snapshot / engine state), so its row carries only identity +
        // kind + status. The api reactor calls this in the same commit as the first run's `delegate`, before
        // that delegation's caller FK. Idempotent across runs and restarts.
        await drizzleTx
          .insert(instances)
          .values({ id: apiRootId, projectId, kind: "api", status: "running" })
          .onConflictDoNothing();
      },
      putFfiCall: async (call) => {
        await drizzleTx
          .insert(ffiCalls)
          .values({
            delegation: call.delegation,
            projectId,
            instanceId: call.instance,
            snapshotId: call.snapshot,
            key: call.key,
            argument: call.argument,
            callerReactor: call.caller,
            status: call.status,
          })
          .onConflictDoUpdate({ target: ffiCalls.delegation, set: { status: call.status } });
      },
      dropFfiCall: async (delegation) => {
        await drizzleTx.delete(ffiCalls).where(eq(ffiCalls.delegation, delegation));
      },
    };
  }
}
