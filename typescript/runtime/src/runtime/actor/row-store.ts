// The ONE turn-commit implementation both storing backends share. `DbPersistence` (drizzle) and
// `StoringPersistence` (the in-memory recovery-test twin) used to hand-mirror each other's semantics —
// seal placement, run-outcome stickiness, envelope⋈extension join guards, corrupt-row surfacing — across
// ~1400 lines; any drift between them made recovery tests lie about production. This module folds those
// semantics into `storeTx` / `storeLoader` over a `RowStore` port, so a backend supplies ONLY row CRUD:
// drizzle maps each method to a statement (cascades delegated to the FKs), the Map twin mutates its maps
// (mimicking the cascades in one place). Write ordering stays the caller's (the reactor protocol writes
// envelope-first and drops last); this layer never reorders.
//
// Sealing is decided here, uniformly for both backends: every payload that can carry a `Value` seals on
// write and unseals on read — including the whole external-call extension document, one rule instead of a
// per-kind column enumeration. A backend below this line only ever sees at-rest (sealed) rows.

import type { Json } from "@katari-lang/types";
import {
  type ExternalCallStatus,
  isTerminalRunState,
  type RunState,
} from "../../db/tables/execution.js";
import type { InstanceKind } from "../engine/types.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import type { BlobId, DelegationId, EscalationId, InstanceId, OutboxSeq, ScopeId } from "../ids.js";
import type { Value } from "../value/types.js";
import type {
  Loader,
  OutboxMessage,
  PersistedCapabilityRoute,
  PersistedDelegation,
  PersistedEscalation,
  PersistedExternalCall,
  PersistedExternalCallRow,
  PersistedRun,
  PersistedRunEscalationAudit,
  PersistenceTx,
} from "./persistence.js";
import {
  deserializeProject,
  type PersistedBlob,
  type PersistedCoreInstance,
  type PersistedInstance,
  type PersistedInstanceEnvelope,
  type PersistedScope,
  type PersistedThread,
} from "./persistence-codec.js";
import { sealForStorage, unsealFromStorage } from "./seal.js";

/** One `core` envelope ⋈ `core_instances` row as the store reads it back. The envelope's routing fields
 *  come back nullable (the columns are), and the loader — not the store — decides a null is corrupt. */
export interface StoredCoreJoin {
  id: InstanceId;
  delegationId: DelegationId | null;
  callerReactor: ReactorName | null;
  runId: InstanceId | null;
  status: PersistedInstanceEnvelope["status"];
  core: PersistedCoreInstance;
}

/** One external envelope ⋈ `external_call_instances` row as the store reads it back — same nullable
 *  envelope fields, same division of labour (the loader guards). The extension is still sealed. */
export interface StoredExternalCallJoin {
  instance: InstanceId;
  delegation: DelegationId | null;
  caller: ReactorName | null;
  run: InstanceId | null;
  status: ExternalCallStatus;
  extension: Json;
}

/** A run's outcome as one prepared write: the shared logic decides WHAT changes (a terminal stamps
 *  `completedAt`; a `cancelReason` rides only on the update that carries one), the store only applies the
 *  patch to the (existing) row. */
export interface RunOutcomePatch {
  state: RunState;
  result: Value | null;
  errorMessage: string | null;
  completedAt?: Date;
  cancelReason?: string | null;
}

/** Row CRUD over one project's logical tables — everything a persistence backend must supply, and nothing
 *  it may decide. A store is constructed project-scoped (and, for the DB, transaction-scoped), so no
 *  method takes a project id. Every payload crossing this port is already at rest (sealed).
 *
 *  Each `put…` doc below names its MUTABLE-ON-CONFLICT fields, and that sentence is the contract both
 *  backends implement — Drizzle as its `onConflictDoUpdate` set, the Map twin as a field merge into the
 *  existing row. A backend must never full-replace a row whose contract names a narrower mutable set, or
 *  the twin stops witnessing production (an immutable column the DB would preserve could silently change
 *  in the Map and hide a reactor writing what it must not). */
export interface RowStore {
  /** Upsert the generic envelope. Only `status` is mutable on conflict (`callerReactor` / `runId` /
   *  `delegationId` are immutable after the summoning turn wrote them). */
  putInstance(row: PersistedInstanceEnvelope): Promise<void>;
  /** Delete an instance, cascading its extension rows / threads / owned scopes and blobs / issued
   *  delegations / raised escalations / capability routes — and, when the instance is a run root, its
   *  run record with the run's audit + journal rows behind it (the DB delegates to its FKs; the Map twin
   *  mimics the same cascade in one place). */
  deleteInstance(id: InstanceId): Promise<void>;
  /** Upsert a live delegation row. Only `state` is mutable on conflict (running → cancelling). */
  putDelegation(row: PersistedDelegation): Promise<void>;
  deleteDelegation(id: DelegationId): Promise<void>;
  /** Insert an open escalation row; a re-open of the same id is a no-op (the row is immutable while open). */
  insertEscalation(row: PersistedEscalation): Promise<void>;
  deleteEscalation(id: EscalationId): Promise<void>;
  /** Upsert the core extension row. Only `engineState` and `ambientGenerics` are mutable on conflict —
   *  and a `null` `ambientGenerics` leaves the stored value untouched (the substitution is set at summon,
   *  never cleared); `target` / `snapshotId` are immutable after the summoning turn. */
  putCore(row: PersistedCoreInstance): Promise<void>;
  /** Replace one instance's thread rows wholesale (the trees are small and evolve as a unit). */
  replaceThreads(instance: InstanceId, threads: PersistedThread[]): Promise<void>;
  /** Upsert one external call's extension row. Every non-key field (`status`, `extension`) is mutable —
   *  a full-row replace. */
  putExternalCall(row: PersistedExternalCallRow): Promise<void>;
  /** Upsert one capability route; every field is immutable, so a re-register is a no-op. */
  putRoute(route: PersistedCapabilityRoute): Promise<void>;
  /** Upsert one scope row. Every non-key field (`parentScopeId`, `ownerInstanceId`, `values`) is
   *  mutable — a full-row replace. */
  putScope(row: PersistedScope): Promise<void>;
  deleteScope(scopeId: ScopeId): Promise<void>;
  /** Upsert one blob row. Only the owner is mutable on conflict (the descriptor is content-addressed). */
  putBlob(row: PersistedBlob): Promise<void>;
  deleteBlob(id: BlobId): Promise<void>;
  /** Insert a run's launch record; a replayed launch turn is a no-op (the row is already there). */
  insertRun(row: PersistedRun): Promise<void>;
  /** Apply an outcome patch to an existing run row (a patch for an unknown run is a no-op). */
  updateRun(run: InstanceId, patch: RunOutcomePatch): Promise<void>;
  /** Append an answered-escalation audit row; a replayed answer turn is a no-op (same key). */
  insertAudit(row: PersistedRunEscalationAudit): Promise<void>;
  deleteOutbox(seq: OutboxSeq): Promise<void>;
  insertOutbox(rows: OutboxMessage[]): Promise<void>;
  appendJournal(events: ExternalEvent[]): Promise<void>;

  /** The live delegations issued by `from` (every stored row is live — a terminal one is deleted). */
  delegationsFrom(from: ReactorName): Promise<PersistedDelegation[]>;
  /** The open escalations matching the filter (every stored row is open — answering deletes it). */
  openEscalations(filter: { from?: ReactorName; to?: ReactorName }): Promise<PersistedEscalation[]>;
  /** The `core` envelopes joined to their extension rows. */
  coreInstances(): Promise<StoredCoreJoin[]>;
  threads(): Promise<PersistedThread[]>;
  scopes(): Promise<PersistedScope[]>;
  blobs(): Promise<PersistedBlob[]>;
  /** The `kind` envelopes joined to their external-call extension rows. */
  externalCalls(kind: InstanceKind): Promise<StoredExternalCallJoin[]>;
  /** The undrained outbox, in insertion order. */
  pendingOutbox(): Promise<OutboxMessage[]>;
}

/** The per-turn write surface over one store: seal every value-bearing payload, prepare the run-outcome
 *  patch, and hand each write to the store in the caller's (FK-safe) order. */
export function storeTx(store: RowStore): PersistenceTx {
  return {
    base: {
      putInstanceEnvelope: (envelope) => store.putInstance(envelope),
      putDelegation: (row) => store.putDelegation(row),
      deleteDelegation: (delegation) => store.deleteDelegation(delegation),
      putEscalation: (row) =>
        store.insertEscalation({ ...row, argument: sealForStorage(row.argument) }),
      deleteEscalation: (escalation) => store.deleteEscalation(escalation),
      dropInstance: (instanceId) => store.deleteInstance(instanceId),
    },
    core: {
      putCoreInstance: async (serialized) => {
        const instance = serialized.instance;
        // `engineState.cancelExits` can carry private exit values, and a thread payload embeds in-flight
        // values, so both seal like any payload.
        await store.putCore({ ...instance, engineState: sealForStorage(instance.engineState) });
        await store.replaceThreads(
          instance.instanceId,
          serialized.threads.map((thread) => ({
            ...thread,
            payload: sealForStorage(thread.payload),
          })),
        );
      },
    },
    api: {
      putRun: (run) => store.insertRun({ ...run, argument: sealForStorage(run.argument) }),
      setRunOutcome: (outcome) =>
        // The run's durable outcome (the delegation row is gone on terminal). `completedAt` is stamped only
        // at a terminal state; a `cancelReason` (present only on a cancel's `cancelling` update) rides along.
        store.updateRun(outcome.run, {
          state: outcome.state,
          result: sealForStorage(outcome.result),
          errorMessage: outcome.errorMessage,
          ...(isTerminalRunState(outcome.state) ? { completedAt: new Date() } : {}),
          ...(outcome.cancelReason !== undefined ? { cancelReason: outcome.cancelReason } : {}),
        }),
      putRunEscalationAudit: (audit) =>
        store.insertAudit({
          ...audit,
          question: sealForStorage(audit.question),
          answer: sealForStorage(audit.answer),
        }),
    },
    external: {
      // The ONE seal rule for external calls: the whole extension document seals, wherever its private
      // Value nodes sit (a webhook callback, an mcp descriptor, a watch's deliver_to) — the port never
      // enumerates them by kind.
      putCall: (row) => store.putExternalCall({ ...row, extension: sealForStorage(row.extension) }),
    },
    routes: {
      putRoute: (route) => store.putRoute(route),
    },
    pool: {
      // The scope's variables are the primary at-rest home of secret values; each private one seals.
      putScope: (scope) => store.putScope({ ...scope, values: sealForStorage(scope.values) }),
      deleteScope: (scopeId) => store.deleteScope(scopeId),
      putBlob: (blob) => store.putBlob(blob),
      dropBlob: (blobId) => store.deleteBlob(blobId),
    },
    outbox: {
      consumeOutbox: (seq) => store.deleteOutbox(seq),
      // An event carries delegate arguments / ack values, so private ones seal in the outbox too.
      produceOutbox: (messages) =>
        store.insertOutbox(
          messages.map((message) => ({ seq: message.seq, event: sealForStorage(message.event) })),
        ),
    },
    journal: {
      // Sealed like the outbox — the journal holds the same events, at rest.
      appendEvents: (events) => store.appendJournal(events.map((event) => sealForStorage(event))),
    },
  };
}

/** The per-owner read surface over one store: unseal every value-bearing payload and apply the row
 *  guards — a corrupt core envelope surfaces loudly, an external row whose envelope routing is incomplete
 *  is skipped (its delegation / caller / run are written together at delegate-receive, so a null in any
 *  means the row is not a loadable call). */
export function storeLoader(store: RowStore): Loader {
  return {
    base: {
      delegations: (from) => store.delegationsFrom(from),
      raisedEscalations: async (from) => unsealEscalations(await store.openEscalations({ from })),
    },
    core: {
      engine: async () => {
        const [instanceRows, threadRows, scopeRows, blobRows] = await Promise.all([
          store.coreInstances(),
          store.threads(),
          store.scopes(),
          store.blobs(),
        ]);
        const instances: PersistedInstance[] = instanceRows.map((row) => {
          // A core instance is always summoned, so its envelope `caller_reactor` / `run_id` are non-null;
          // a null here is a corrupt row, surfaced loudly rather than papered over with a default.
          if (row.callerReactor === null) {
            throw new Error(`core instance ${row.id} has no caller_reactor (corrupt envelope)`);
          }
          if (row.runId === null) {
            throw new Error(`core instance ${row.id} has no run_id (corrupt envelope)`);
          }
          return {
            id: row.id,
            delegationId: row.delegationId,
            callerReactor: row.callerReactor,
            runId: row.runId,
            target: row.core.target,
            snapshotId: row.core.snapshotId,
            status: row.status,
            ambientGenerics: row.core.ambientGenerics,
            engineState: unsealFromStorage(row.core.engineState),
          };
        });
        return deserializeProject(
          instances,
          threadRows.map((thread) => ({ ...thread, payload: unsealFromStorage(thread.payload) })),
          scopeRows.map((scope) => ({ ...scope, values: unsealFromStorage(scope.values) })),
          blobRows,
        );
      },
    },
    api: {
      answerableEscalations: async () =>
        unsealEscalations(await store.openEscalations({ to: "api" })),
    },
    external: {
      instances: async (reactor) => {
        const rows = await store.externalCalls(reactor);
        return rows.flatMap((row): PersistedExternalCall[] =>
          row.delegation === null || row.caller === null || row.run === null
            ? []
            : [
                {
                  delegation: row.delegation,
                  instance: row.instance,
                  caller: row.caller,
                  run: row.run,
                  status: row.status,
                  extension: unsealFromStorage(row.extension),
                },
              ],
        );
      },
    },
    outbox: {
      pending: async () =>
        (await store.pendingOutbox()).map((row) => ({
          seq: row.seq,
          event: unsealFromStorage(row.event),
        })),
    },
  };
}

/** Unseal the argument each reloaded open escalation carries (the one value-bearing field on the row). */
function unsealEscalations(rows: PersistedEscalation[]): PersistedEscalation[] {
  return rows.map((row) => ({ ...row, argument: unsealFromStorage(row.argument) }));
}
