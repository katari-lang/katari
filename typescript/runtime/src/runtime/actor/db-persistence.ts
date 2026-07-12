// Drizzle-backed persistence: one turn = one `transaction`, in which the reacting reactor writes its own
// state through a `PersistenceTx` and the substrate writes the transactional outbox. A delegation row is
// upserted by its caller, an escalation by its raiser, a still-running instance's Layer 2 (instance row +
// thread tree) is replaced wholesale, scopes are upserted independently by the `ResourcePool` (`putScope`),
// and a completed instance is dropped (cascade). Writing all of it in a single DB transaction is what keeps
// an edge's durable row from lagging the engine threads that reference it. Loading returns the engine graph
// plus the live (running / cancelling) delegation rows and open escalations each reactor reloads as its own.

import { and, asc, eq } from "drizzle-orm";
import type { AnyPgColumn, PgTable } from "drizzle-orm/pg-core";
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
  mcpInstances,
  mcpProvideInstances,
  mcpServeInstances,
  outbox,
  runEscalationsAudit,
  runEvents,
  runs,
  timeInstances,
  webhookInstances,
} from "../../db/tables/execution.js";
import type { InstanceKind } from "../engine/types.js";
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
  PersistedCallEnvelope,
  PersistedDelegation,
  PersistedEscalationRelay,
  PersistedInnerCall,
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
      // Every stored delegation is live (running / cancelling) — a terminal one is deleted — so no state filter.
      const rows = await this.db
        .select({
          id: delegations.id,
          callerInstanceId: delegations.callerInstanceId,
          fromReactor: delegations.fromReactor,
          toReactor: delegations.toReactor,
          state: delegations.state,
        })
        .from(delegations)
        .where(and(eq(delegations.projectId, projectId), eq(delegations.fromReactor, from)));
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
    };
    const openEscalationsWhere = async (filter: {
      from?: ReactorName;
      to?: ReactorName;
    }): Promise<PersistedOpenEscalation[]> => {
      // Every stored escalation is open (answering deletes it), so existence alone selects the open ones.
      const conditions = [eq(escalations.projectId, projectId)];
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
        run: row.runId as InstanceId,
        request: row.request,
        argument: unsealFromStorage(row.argument),
      }));
    };
    // The shared "envelope ⋈ extension where kind" join every call reactor's `instances()` loader runs —
    // the four extension tables differ only in their columns, so the select, the kind filter, and the
    // null guards (a live call's delegation / caller / run are written together at delegate-receive, so
    // a null in any is a dropped or corrupt row) live here once; each loader is only its projection.
    const callInstancesOf = async <
      ExtensionTable extends PgTable & { instanceId: AnyPgColumn },
      Instance,
    >(
      kind: InstanceKind,
      extensionTable: ExtensionTable,
      project: (call: PersistedCallEnvelope, extension: ExtensionTable["$inferSelect"]) => Instance,
    ): Promise<Instance[]> => {
      // The join argument is widened to the concrete constraint: drizzle guards it with a conditional
      // type that cannot reduce over an unresolved type parameter, while the concrete intersection
      // reduces fine — and the selection keeps `extension` typed by `ExtensionTable`.
      const joined: PgTable & { instanceId: AnyPgColumn } = extensionTable;
      const rows = await this.db
        .select({
          delegation: instances.delegationId,
          instance: instances.id,
          caller: instances.callerReactor,
          run: instances.runId,
          extension: extensionTable,
        })
        .from(instances)
        .innerJoin(joined, eq(instances.id, joined.instanceId))
        .where(and(eq(instances.projectId, projectId), eq(instances.kind, kind)));
      return rows.flatMap((row) =>
        row.delegation === null || row.caller === null || row.run === null
          ? []
          : [
              project(
                {
                  delegation: row.delegation as DelegationId,
                  instance: row.instance as InstanceId,
                  caller: row.caller,
                  run: row.run as InstanceId,
                },
                row.extension,
              ),
            ],
      );
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
              .where(and(eq(instances.projectId, projectId), eq(instances.kind, "core"))),
            this.db.select().from(threads).where(eq(threads.projectId, projectId)),
            this.db.select().from(scopes).where(eq(scopes.projectId, projectId)),
            this.db.select().from(blobs).where(eq(blobs.projectId, projectId)),
          ]);
          const persistedInstances: PersistedInstance[] = instanceRows.map((row) => {
            // A core instance is always summoned, so its envelope `caller_reactor` / `run_id` are non-null;
            // a null here is a corrupt row, surfaced loudly rather than papered over with a default.
            if (row.callerReactor === null) {
              throw new Error(`core instance ${row.id} has no caller_reactor (corrupt envelope)`);
            }
            if (row.runId === null) {
              throw new Error(`core instance ${row.id} has no run_id (corrupt envelope)`);
            }
            return {
              id: row.id as InstanceId,
              delegationId: row.delegationId as PersistedInstance["delegationId"],
              callerReactor: row.callerReactor,
              runId: row.runId as InstanceId,
              target: row.target,
              snapshotId: row.snapshotId as SnapshotId,
              status: row.status,
              ambientGenerics: row.ambientGenerics ?? null,
              engineState: unsealFromStorage(row.engineState),
            };
          });
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
            event: unsealFromStorage(row.event),
          }));
        },
      },
      ffi: {
        instances: () =>
          callInstancesOf("ffi", ffiInstances, (call, extension) => ({
            ...call,
            snapshot: extension.snapshotId as SnapshotId,
            key: extension.key,
            status: extension.status,
            relays: brandedRelays(extension.relays),
            innerCalls: brandedInnerCalls(extension.innerCalls),
          })),
      },
      http: {
        instances: () =>
          callInstancesOf("http", httpInstances, (call, extension) => ({
            ...call,
            status: extension.status,
          })),
      },
      mcp: {
        // The mcp call joins its status-only `mcp_instances` row and LEFT-joins BOTH its `mcp_serve_instances`
        // and `mcp_provide_instances` subtypes: a matched serve extension reloads the live endpoint
        // (re-registering its token); a matched provide extension re-registers the live scope (with its
        // descriptor / scope id / still-listing continuation); both absent is a transport call recovered
        // at-most-once. At most one subtype matches. `callInstancesOf` joins one extension table, so the
        // three-table read is spelled here.
        instances: async () => {
          const rows = await this.db
            .select({
              delegation: instances.delegationId,
              instance: instances.id,
              caller: instances.callerReactor,
              run: instances.runId,
              status: mcpInstances.status,
              serve: mcpServeInstances,
              provide: mcpProvideInstances,
            })
            .from(instances)
            .innerJoin(mcpInstances, eq(instances.id, mcpInstances.instanceId))
            .leftJoin(mcpServeInstances, eq(instances.id, mcpServeInstances.instanceId))
            .leftJoin(mcpProvideInstances, eq(instances.id, mcpProvideInstances.instanceId))
            .where(and(eq(instances.projectId, projectId), eq(instances.kind, "mcp")));
          return rows.flatMap((row) => {
            // A live call's delegation / caller / run are written together at delegate-receive, so a null
            // in any is a dropped or corrupt row (the same guard `callInstancesOf` applies).
            if (row.delegation === null || row.caller === null || row.run === null) return [];
            const serve = row.serve;
            const provide = row.provide;
            return [
              {
                delegation: row.delegation as DelegationId,
                instance: row.instance as InstanceId,
                caller: row.caller,
                run: row.run as InstanceId,
                status: row.status,
                serve:
                  serve === null
                    ? null
                    : {
                        snapshotId: serve.snapshotId as SnapshotId,
                        token: serve.serveToken,
                        tools: unsealFromStorage(serve.serveTools),
                        relays: brandedRelays(serve.relays),
                        innerCalls: brandedInnerCalls(serve.innerCalls),
                      },
                provide:
                  provide === null
                    ? null
                    : {
                        snapshotId: provide.snapshotId as SnapshotId,
                        scopeId: provide.scopeId,
                        descriptor: unsealFromStorage(provide.descriptor),
                        continuation:
                          provide.continuation === null
                            ? null
                            : unsealFromStorage(provide.continuation),
                        relays: brandedRelays(provide.relays),
                        innerCalls: brandedInnerCalls(provide.innerCalls),
                      },
              },
            ];
          });
        },
      },
      webhook: {
        // Unlike ffi / http the webhook extension carries the payload (token + callback) a reload
        // re-registers, so an endpoint survives a restart; the sealed callback unseals here.
        instances: () =>
          callInstancesOf("webhook", webhookInstances, (call, extension) => ({
            ...call,
            snapshot: extension.snapshotId as SnapshotId,
            token: extension.token,
            callback: unsealFromStorage(extension.callback),
            status: extension.status,
            relays: brandedRelays(extension.relays),
            innerCalls: brandedInnerCalls(extension.innerCalls),
          })),
      },
      time: {
        // Like webhook, the time extension carries the payload a reload re-arms; the sealed `operation`
        // (whose `watch` variant holds the deliver_to value) unseals here.
        instances: () =>
          callInstancesOf("time", timeInstances, (call, extension) => ({
            ...call,
            snapshot: extension.snapshotId as SnapshotId,
            operation: unsealFromStorage(extension.operation),
            status: extension.status,
            relays: brandedRelays(extension.relays),
            innerCalls: brandedInnerCalls(extension.innerCalls),
          })),
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
          callerReactor: envelope.callerReactor,
          runId: envelope.runId,
          status: envelope.status,
        })
        // `caller_reactor` / `run_id` are immutable (the summoner and the run never change), so only
        // `status` is updated on re-upsert.
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
          state: row.state,
        })
        // The only mutable field is `state` (running → cancelling); everything else is immutable at open.
        .onConflictDoUpdate({ target: delegations.id, set: { state: row.state } });
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
              runId: row.run,
              request: row.request,
              argument: sealForStorage(row.argument),
            })
            // An open escalation row is immutable (answering deletes it), so a re-open is a no-op.
            .onConflictDoNothing();
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
          // The bridges carry only routing ids / opaque tokens (no values), so they are not sealed. The
          // branded ids widen to the column's plain-string shape implicitly.
          const relays: Array<{ escalation: string; child: string; childEscalation: string }> =
            row.relays;
          const innerCalls: Array<{ delegation: string; call: string }> = row.innerCalls;
          await drizzleTx
            .insert(ffiInstances)
            .values({
              instanceId: row.instanceId,
              snapshotId: row.snapshotId,
              key: row.key,
              status: row.status,
              relays,
              innerCalls,
            })
            .onConflictDoUpdate({
              target: ffiInstances.instanceId,
              set: { status: row.status, relays, innerCalls },
            });
        },
      },
      http: {
        putHttpInstance: async (row) => {
          await drizzleTx
            .insert(httpInstances)
            .values({
              instanceId: row.instanceId,
              status: row.status,
            })
            .onConflictDoUpdate({ target: httpInstances.instanceId, set: { status: row.status } });
        },
      },
      webhook: {
        putWebhookInstance: async (row) => {
          const relays = row.relays.map((relay) => ({
            escalation: relay.escalation as string,
            child: relay.child as string,
            childEscalation: relay.childEscalation as string,
          }));
          const innerCalls = row.innerCalls.map((inner) => ({
            delegation: inner.delegation as string,
            call: inner.call,
          }));
          // The callback may capture private values (a closure over a secret), so it seals like a scope.
          const callback = sealForStorage(row.callback);
          await drizzleTx
            .insert(webhookInstances)
            .values({
              instanceId: row.instanceId,
              snapshotId: row.snapshotId,
              token: row.token,
              callback,
              status: row.status,
              relays,
              innerCalls,
            })
            .onConflictDoUpdate({
              target: webhookInstances.instanceId,
              set: { status: row.status, relays, innerCalls },
            });
        },
      },
      time: {
        putTimeInstance: async (row) => {
          const relays = row.relays.map((relay) => ({
            escalation: relay.escalation as string,
            child: relay.child as string,
            childEscalation: relay.childEscalation as string,
          }));
          const innerCalls = row.innerCalls.map((inner) => ({
            delegation: inner.delegation as string,
            call: inner.call,
          }));
          // The operation evolves (a watch's cursor advances per tick) and its `watch` variant embeds the
          // deliver_to value, which may close over a secret — so the whole operation seals and re-writes on
          // update, unlike webhook's immutable callback.
          const operation = sealForStorage(row.operation);
          await drizzleTx
            .insert(timeInstances)
            .values({
              instanceId: row.instanceId,
              snapshotId: row.snapshotId,
              operation,
              status: row.status,
              relays,
              innerCalls,
            })
            .onConflictDoUpdate({
              target: timeInstances.instanceId,
              set: { operation, status: row.status, relays, innerCalls },
            });
        },
      },
      mcp: {
        putMcpInstance: async (row) => {
          // The status-only `mcp_instances` row first (the serve / provide subtypes FK it). Immutable after
          // open, only `status` updates on re-upsert.
          await drizzleTx
            .insert(mcpInstances)
            .values({ instanceId: row.instanceId, status: row.status })
            .onConflictDoUpdate({
              target: mcpInstances.instanceId,
              set: { status: row.status },
            });
          if (row.serve !== null) {
            const serve = row.serve;
            const relays = serve.relays.map((relay) => ({
              escalation: relay.escalation as string,
              child: relay.child as string,
              childEscalation: relay.childEscalation as string,
            }));
            const innerCalls = serve.innerCalls.map((inner) => ({
              delegation: inner.delegation as string,
              call: inner.call,
            }));
            // The served tools record may capture private values (a closure over a secret), so it seals like
            // the webhook callback. The token / tools / snapshot are immutable after open, so only the
            // inner-delegation bridges update on re-upsert.
            const serveTools = sealForStorage(serve.tools);
            await drizzleTx
              .insert(mcpServeInstances)
              .values({
                instanceId: row.instanceId,
                snapshotId: serve.snapshotId,
                serveToken: serve.token,
                serveTools,
                relays,
                innerCalls,
              })
              .onConflictDoUpdate({
                target: mcpServeInstances.instanceId,
                set: { relays, innerCalls },
              });
          }
          if (row.provide !== null) {
            const provide = row.provide;
            const relays = provide.relays.map((relay) => ({
              escalation: relay.escalation as string,
              child: relay.child as string,
              childEscalation: relay.childEscalation as string,
            }));
            const innerCalls = provide.innerCalls.map((inner) => ({
              delegation: inner.delegation as string,
              call: inner.call,
            }));
            // The descriptor's auth may be a secret, and a continuation closes over the block's scope (private
            // values reachable), so both seal like the webhook callback. The scope id / descriptor / snapshot
            // are immutable after open; the continuation flips to null when it is dispatched and the
            // inner-delegation bridges grow, so those update on re-upsert.
            const descriptor = sealForStorage(provide.descriptor);
            const continuation =
              provide.continuation === null ? null : sealForStorage(provide.continuation);
            await drizzleTx
              .insert(mcpProvideInstances)
              .values({
                instanceId: row.instanceId,
                snapshotId: provide.snapshotId,
                scopeId: provide.scopeId,
                descriptor,
                continuation,
                relays,
                innerCalls,
              })
              .onConflictDoUpdate({
                target: mcpProvideInstances.instanceId,
                set: { continuation, relays, innerCalls },
              });
          }
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
              // An event carries delegate arguments / ack values, so private ones seal in the outbox too.
              event: sealForStorage(message.event),
            })),
          );
        },
      },
      journal: {
        appendEvents: async (events) => {
          if (events.length === 0) return;
          // A multi-row insert assigns the `seq` bigserial in row order, so the array's (causal production)
          // order is the journal order. Sealed like the outbox — the journal holds the same events, at rest.
          await drizzleTx.insert(runEvents).values(
            events.map((event) => ({
              projectId,
              runId: event.run,
              event: sealForStorage(event),
            })),
          );
        },
      },
    };
  }
}

/** Rebrand a stored relay bridge's plain-string ids (the jsonb column shape) into the loaded row's ids —
 *  shared by the ffi and webhook loaders, whose extensions persist the same bridge shape. */
function brandedRelays(
  relays: Array<{ escalation: string; child: string; childEscalation: string }>,
): PersistedEscalationRelay[] {
  return relays.map((relay) => ({
    escalation: relay.escalation as EscalationId,
    child: relay.child as DelegationId,
    childEscalation: relay.childEscalation as EscalationId,
  }));
}

/** Rebrand a stored inner-call bridge's plain-string delegation id, like `brandedRelays`. */
function brandedInnerCalls(
  innerCalls: Array<{ delegation: string; call: string }>,
): PersistedInnerCall[] {
  return innerCalls.map((inner) => ({
    delegation: inner.delegation as DelegationId,
    call: inner.call,
  }));
}
