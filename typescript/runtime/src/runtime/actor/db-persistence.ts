// Drizzle-backed persistence: one turn = one `transaction`, in which the reacting reactor writes its own
// state through a `PersistenceTx` and the substrate writes the transactional outbox. A delegation row is
// upserted by its caller, an escalation by its raiser, a still-running instance's Layer 2 (instance row +
// thread tree) is replaced wholesale, scopes are upserted independently by the `ResourcePool` (`putScope`),
// and a completed instance is dropped (cascade). Writing all of it in a single DB transaction is what keeps
// an edge's durable row from lagging the engine threads that reference it. Loading returns the engine graph
// plus the live (running / cancelling) delegation rows and open escalations each reactor reloads as its own.

import { and, asc, eq, inArray } from "drizzle-orm";
import type { Database } from "../../db/client.js";
import { blobs, scopes, threads } from "../../db/tables/engine.js";
import {
  coreInstances,
  delegations,
  escalations,
  ffiInstances,
  httpInstances,
  instances,
  isTerminalRunState,
  LIVE_DELEGATION_STATES,
  outbox,
  runEscalationsAudit,
  runs,
} from "../../db/tables/execution.js";
import type { ReactorName } from "../event/types.js";
import type {
  BlobId,
  DelegationId,
  EscalationId,
  InstanceId,
  OutboxSeq,
  ProjectId,
  SnapshotId,
} from "../ids.js";
import type {
  BaseTx,
  Loader,
  PersistedDelegation,
  PersistedOpenEscalation,
  Persistence,
  PersistenceTx,
} from "./persistence.js";
import {
  deserializeProject,
  type PersistedBlob,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
} from "./persistence-codec.js";
import { sealForStorage, unsealFromStorage } from "./seal.js";

export class DbPersistence implements Persistence {
  constructor(private readonly db: Database) {}

  async load(projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    await body(this.loader(projectId));
  }

  /** The per-reactor read surface: each method runs one query, self-selecting by reactor. Reactivation runs
   *  before any commit on a serial actor, so separate reads see a consistent snapshot without a read tx. */
  private loader(projectId: ProjectId): Loader {
    // Shared, reactor-parameterized queries — core / api both read live delegations + open escalations, each
    // self-selecting by reactor.
    const delegationsFrom = async (from: ReactorName): Promise<PersistedDelegation[]> => {
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
                argument: unsealFromStorage(row.argument),
                state: row.state,
                result: unsealFromStorage(row.result),
                errorMessage: row.errorMessage,
              },
            ],
      );
    };
    const openEscalationsWhere = async (filter: {
      from?: ReactorName;
      to?: ReactorName;
    }): Promise<PersistedOpenEscalation[]> => {
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
        argument: unsealFromStorage(row.argument),
      }));
    };
    return {
      base: {
        delegations: (from) => delegationsFrom(from),
        raisedEscalations: (from) => openEscalationsWhere({ from }),
      },
      core: {
        engine: async () => {
          const [instanceRows, threadRows, scopeRows, blobRows] = await Promise.all([
            // The engine graph is the `core` instances: the envelope joined to its `core_instances` extension.
            this.db
              .select({
                id: instances.id,
                delegationId: instances.delegationId,
                status: instances.status,
                target: coreInstances.target,
                snapshotId: coreInstances.snapshotId,
                ambientGenerics: coreInstances.ambientGenerics,
                engineState: coreInstances.engineState,
              })
              .from(instances)
              .innerJoin(coreInstances, eq(instances.id, coreInstances.instanceId))
              .where(and(eq(instances.projectId, projectId), eq(instances.kind, "core"))),
            this.db.select().from(threads).where(eq(threads.projectId, projectId)),
            this.db.select().from(scopes).where(eq(scopes.projectId, projectId)),
            this.db.select().from(blobs).where(eq(blobs.projectId, projectId)),
          ]);
          const persistedInstances: PersistedInstance[] = instanceRows.map((row) => ({
            id: row.id as InstanceId,
            delegationId: row.delegationId as PersistedInstance["delegationId"],
            target: row.target,
            snapshotId: row.snapshotId as SnapshotId,
            status: row.status,
            ambientGenerics: row.ambientGenerics ?? null,
            engineState: unsealFromStorage(row.engineState),
          }));
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
            payload: unsealFromStorage(row.payload),
          }));
          const persistedScopes: PersistedScope[] = scopeRows.map((row) => ({
            projectId: row.projectId as ProjectId,
            scopeId: row.scopeId,
            parentScopeId: row.parentScopeId,
            ownerInstanceId: row.ownerInstanceId as InstanceId | null,
            values: unsealFromStorage(row.values),
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
      },
      api: {
        answerableEscalations: () => openEscalationsWhere({ to: "api" }),
      },
      outbox: {
        pending: async () => {
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
            event: unsealFromStorage(row.event),
          }));
        },
      },
      ffi: {
        instances: async () => {
          // The in-flight ffi calls are the `ffi` instances: the envelope (its `delegation_id` is the call's
          // delegation) joined to its `ffi_instances` extension.
          const rows = await this.db
            .select({
              delegation: instances.delegationId,
              instance: instances.id,
              snapshot: ffiInstances.snapshotId,
              key: ffiInstances.key,
              argument: ffiInstances.argument,
              caller: ffiInstances.callerReactor,
              status: ffiInstances.status,
            })
            .from(instances)
            .innerJoin(ffiInstances, eq(instances.id, ffiInstances.instanceId))
            .where(and(eq(instances.projectId, projectId), eq(instances.kind, "ffi")));
          return rows.flatMap((row) =>
            row.delegation === null
              ? []
              : [
                  {
                    delegation: row.delegation as DelegationId,
                    instance: row.instance as InstanceId,
                    snapshot: row.snapshot as SnapshotId,
                    key: row.key,
                    argument: unsealFromStorage(row.argument),
                    caller: row.caller,
                    status: row.status,
                  },
                ],
          );
        },
      },
      http: {
        instances: async () => {
          // The in-flight http calls are the `http` instances: the envelope (its `delegation_id` is the
          // call's delegation) joined to its `http_instances` extension (which carries the precise status).
          const rows = await this.db
            .select({
              delegation: instances.delegationId,
              instance: instances.id,
              caller: httpInstances.callerReactor,
              status: httpInstances.status,
            })
            .from(instances)
            .innerJoin(httpInstances, eq(instances.id, httpInstances.instanceId))
            .where(and(eq(instances.projectId, projectId), eq(instances.kind, "http")));
          return rows.flatMap((row) =>
            row.delegation === null
              ? []
              : [
                  {
                    delegation: row.delegation as DelegationId,
                    instance: row.instance as InstanceId,
                    caller: row.caller,
                    status: row.status,
                  },
                ],
          );
        },
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
    // The `base` port's generic-row writers, used by every reactor through `persistBase`.
    const putInstanceEnvelope: BaseTx["putInstanceEnvelope"] = async (envelope) => {
      await drizzleTx
        .insert(instances)
        .values({
          id: envelope.id,
          projectId,
          kind: envelope.kind,
          delegationId: envelope.delegationId,
          status: envelope.status,
        })
        .onConflictDoUpdate({ target: instances.id, set: { status: envelope.status } });
    };
    const putDelegation: BaseTx["putDelegation"] = async (row) => {
      await drizzleTx
        .insert(delegations)
        .values({
          id: row.delegation,
          projectId,
          callerInstanceId: row.caller,
          fromReactor: row.fromReactor,
          toReactor: row.toReactor,
          target: row.target,
          argument: sealForStorage(row.argument),
          state: row.state,
          result: sealForStorage(row.result),
          errorMessage: row.errorMessage,
        })
        .onConflictDoUpdate({
          target: delegations.id,
          set: {
            state: row.state,
            result: sealForStorage(row.result),
            errorMessage: row.errorMessage,
          },
        });
    };
    const dropInstance = async (instanceId: InstanceId) => {
      // Cascade removes the instance's extension / threads / the scopes it still owns / owned delegations +
      // escalations. A scope its result released to in-transit (`owner = null`) is not owned by it, so it
      // survives; the pool re-writes it in this same commit (after this drop) with its new owner.
      await drizzleTx
        .delete(instances)
        .where(and(eq(instances.projectId, projectId), eq(instances.id, instanceId)));
    };
    return {
      base: {
        putInstanceEnvelope,
        putDelegation,
        dropInstance,
        deleteDelegation: async (delegation) => {
          await drizzleTx
            .delete(delegations)
            .where(and(eq(delegations.projectId, projectId), eq(delegations.id, delegation)));
        },
        deleteEscalation: async (escalation) => {
          await drizzleTx
            .delete(escalations)
            .where(and(eq(escalations.projectId, projectId), eq(escalations.id, escalation)));
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
              argument: sealForStorage(row.argument),
              state: row.state,
              answer: sealForStorage(row.answer),
            })
            .onConflictDoUpdate({
              target: escalations.id,
              set: { state: row.state, answer: sealForStorage(row.answer) },
            });
        },
      },
      core: {
        putCoreInstance: async (serialized) => {
          const instance = serialized.instance;
          await drizzleTx
            .insert(coreInstances)
            .values({
              instanceId: instance.instanceId,
              target: instance.target,
              snapshotId: instance.snapshotId,
              ambientGenerics: instance.ambientGenerics ?? undefined,
              // `engineState.cancelExits` can carry private exit values, so it seals like any payload.
              engineState: sealForStorage(instance.engineState),
            })
            .onConflictDoUpdate({
              target: coreInstances.instanceId,
              set: {
                engineState: sealForStorage(instance.engineState),
                ambientGenerics: instance.ambientGenerics ?? undefined,
              },
            });
          // Replace the instance's thread rows wholesale (the trees are small). Scopes are NOT here — they
          // persist independently through `putScope`. A thread payload embeds in-flight values, so it seals.
          await drizzleTx
            .delete(threads)
            .where(
              and(eq(threads.projectId, projectId), eq(threads.instanceId, instance.instanceId)),
            );
          if (serialized.threads.length > 0)
            await drizzleTx.insert(threads).values(
              serialized.threads.map((thread) => ({
                ...thread,
                payload: sealForStorage(thread.payload),
              })),
            );
        },
      },
      api: {
        putRun: async (run) => {
          await drizzleTx
            .insert(runs)
            .values({
              id: run.run,
              projectId,
              snapshotId: run.snapshotId,
              name: run.name,
              qualifiedName: run.qualifiedName,
              argument: sealForStorage(run.argument),
            })
            .onConflictDoNothing();
        },
        setRunOutcome: async (outcome) => {
          // The run's durable outcome (the delegation row is gone on terminal). `completedAt` is stamped only
          // at a terminal state; a `cancelReason` (present only on a cancel's `cancelling` update) rides along.
          await drizzleTx
            .update(runs)
            .set({
              state: outcome.state,
              result: sealForStorage(outcome.result),
              errorMessage: outcome.errorMessage,
              ...(isTerminalRunState(outcome.state) ? { completedAt: new Date() } : {}),
              ...(outcome.cancelReason !== undefined ? { cancelReason: outcome.cancelReason } : {}),
            })
            .where(and(eq(runs.projectId, projectId), eq(runs.id, outcome.run)));
        },
        putRunEscalationAudit: async (audit) => {
          await drizzleTx
            .insert(runEscalationsAudit)
            .values({
              runId: audit.run,
              escalationId: audit.escalation,
              question: sealForStorage(audit.question),
              answer: sealForStorage(audit.answer),
            })
            .onConflictDoNothing();
        },
      },
      ffi: {
        putFfiInstance: async (row) => {
          await drizzleTx
            .insert(ffiInstances)
            .values({
              instanceId: row.instanceId,
              snapshotId: row.snapshotId,
              key: row.key,
              argument: sealForStorage(row.argument),
              callerReactor: row.callerReactor,
              status: row.status,
            })
            .onConflictDoUpdate({ target: ffiInstances.instanceId, set: { status: row.status } });
        },
      },
      http: {
        putHttpInstance: async (row) => {
          await drizzleTx
            .insert(httpInstances)
            .values({
              instanceId: row.instanceId,
              callerReactor: row.callerReactor,
              status: row.status,
            })
            .onConflictDoUpdate({ target: httpInstances.instanceId, set: { status: row.status } });
        },
      },
      pool: {
        putScope: async (scope) => {
          await drizzleTx
            .insert(scopes)
            .values({
              projectId,
              scopeId: scope.scopeId,
              parentScopeId: scope.parentScopeId,
              ownerInstanceId: scope.ownerInstanceId,
              // The scope's variables are the primary at-rest home of secret values; each private one seals.
              values: sealForStorage(scope.values),
            })
            .onConflictDoUpdate({
              target: [scopes.projectId, scopes.scopeId],
              set: {
                parentScopeId: scope.parentScopeId,
                ownerInstanceId: scope.ownerInstanceId,
                values: sealForStorage(scope.values),
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
      },
      outbox: {
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
              // An event carries delegate arguments / ack values, so private ones seal in the outbox too.
              event: sealForStorage(message.event),
            })),
          );
        },
      },
    };
  }
}
