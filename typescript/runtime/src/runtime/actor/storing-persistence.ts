// An in-memory `Persistence` that actually *stores* the serialised rows (unlike `InMemoryPersistence`'s
// no-op), so the recovery path — commit at the batch boundary, then reload + reactivate in a fresh actor —
// is exercisable without Postgres. It runs the SAME shared turn-commit logic as `DbPersistence`
// (`row-store.ts`: seal placement, run-outcome stickiness, join guards), so the twin cannot drift from
// production semantics; only the row CRUD differs — a `MapRowStore` whose `deleteInstance` mimics the DB's
// ON DELETE CASCADE in one place. There is no real atomicity to enforce (a single-threaded twin), so a
// transaction applies each write as it is called; the FK / cascade order is the caller's, as in the DB.

import type { RunState } from "../../db/tables/execution.js";
import type { ExternalEvent, ReactorName } from "../event/types.js";
import type {
  BlobId,
  DelegationId,
  EscalationId,
  InstanceId,
  OutboxSeq,
  ProjectId,
} from "../ids.js";
import type { Value } from "../value/types.js";
import type {
  Loader,
  OutboxMessage,
  PersistedCapabilityRoute,
  PersistedDelegation,
  PersistedEscalation,
  PersistedExternalCallRow,
  PersistedRun,
  PersistedRunEscalationAudit,
  Persistence,
  PersistenceTx,
} from "./persistence.js";
import type {
  PersistedBlob,
  PersistedCoreInstance,
  PersistedInstanceEnvelope,
  PersistedScope,
  PersistedThread,
} from "./persistence-codec.js";
import { type RowStore, type RunOutcomePatch, storeLoader, storeTx } from "./row-store.js";
import { unsealFromStorage } from "./seal.js";

/** A stored run record: its launch metadata plus its durable state / outcome (the run delegation row is
 *  deleted on terminal, so this is the run's source of truth). */
interface StoredRun extends PersistedRun {
  state: RunState;
  result: Value | null;
  errorMessage: string | null;
  cancelReason: string | null;
  completedAt: Date | null;
}

/** The Map-backed row CRUD — one Map per logical table, keyed as the DB is. Payloads arrive already
 *  sealed (the shared logic owns the seal boundary), so what these maps hold is the at-rest form. */
class MapRowStore implements RowStore {
  readonly envelopes = new Map<InstanceId, PersistedInstanceEnvelope>();
  readonly coreRows = new Map<InstanceId, PersistedCoreInstance>();
  readonly threadRows = new Map<InstanceId, PersistedThread[]>();
  readonly externalRows = new Map<InstanceId, PersistedExternalCallRow>();
  readonly routes = new Map<string, PersistedCapabilityRoute>();
  readonly scopeRows = new Map<number, PersistedScope>();
  readonly blobRows = new Map<BlobId, PersistedBlob>();
  readonly delegations = new Map<DelegationId, PersistedDelegation>();
  readonly escalations = new Map<EscalationId, PersistedEscalation>();
  readonly runs = new Map<InstanceId, StoredRun>();
  readonly audits: PersistedRunEscalationAudit[] = [];
  readonly outbox = new Map<OutboxSeq, OutboxMessage>();
  readonly journal: ExternalEvent[] = [];

  async putInstance(row: PersistedInstanceEnvelope): Promise<void> {
    // Merge only the contract's mutable field into an existing row (see `RowStore.putInstance`), so an
    // immutable column the DB would preserve cannot silently change in the twin.
    const existing = this.envelopes.get(row.id);
    this.envelopes.set(row.id, existing === undefined ? row : { ...existing, status: row.status });
  }

  async deleteInstance(id: InstanceId): Promise<void> {
    // The one place the twin mimics the DB's ON DELETE CASCADE: the extension rows keyed by the
    // envelope, the entities the instance owns (issued delegations / raised escalations / scopes /
    // blobs), and its capability routes all die with it.
    this.envelopes.delete(id);
    this.coreRows.delete(id);
    this.threadRows.delete(id);
    this.externalRows.delete(id);
    for (const [token, route] of this.routes) {
      if (route.instance === id) this.routes.delete(token);
    }
    for (const [scopeId, scope] of this.scopeRows) {
      if (scope.ownerInstanceId === id) this.scopeRows.delete(scopeId);
    }
    for (const [blobId, blob] of this.blobRows) {
      if (blob.ownerInstanceId === id) this.blobRows.delete(blobId);
    }
    for (const [delegation, row] of this.delegations) {
      if (row.caller === id) this.delegations.delete(delegation);
    }
    for (const [escalation, row] of this.escalations) {
      if (row.raiser === id) this.escalations.delete(escalation);
    }
    // A run IS its permanent instance (`runs.id` FK), so dropping it cascades the run record and,
    // transitively through the runs FK, the run's audit and journal rows — exactly the DB's edges.
    this.runs.delete(id);
    for (let index = this.audits.length - 1; index >= 0; index -= 1) {
      if (this.audits[index]?.run === id) this.audits.splice(index, 1);
    }
    for (let index = this.journal.length - 1; index >= 0; index -= 1) {
      if (this.journal[index]?.run === id) this.journal.splice(index, 1);
    }
  }

  async putDelegation(row: PersistedDelegation): Promise<void> {
    // Merge only `state` into an existing row (see `RowStore.putDelegation`).
    const existing = this.delegations.get(row.delegation);
    this.delegations.set(
      row.delegation,
      existing === undefined ? row : { ...existing, state: row.state },
    );
  }

  async deleteDelegation(id: DelegationId): Promise<void> {
    this.delegations.delete(id);
  }

  async insertEscalation(row: PersistedEscalation): Promise<void> {
    if (this.escalations.has(row.escalation)) return;
    // Witness the DB's IMMEDIATE (non-deferrable) `raiser_instance_id` FK: a raiser-owned row whose raiser
    // envelope is absent is a dangling insert that real Postgres rejects at statement time (unlike the
    // deferred `delegations.caller_instance_id`). Enforcing it here keeps the twin honest — a reactor that
    // opened a row without persisting its raiser (or that tries to insert one whose raiser is dropped the same
    // batch) passes silently in a lenient Map but crashes production. The shared `flushEscalations` skips a
    // same-batch-dropped raiser's row, so a well-formed commit never reaches this guard.
    if (!this.envelopes.has(row.raiser)) {
      throw new Error(
        `escalations_raiser_instance_id FK: raiser instance ${row.raiser} absent for escalation ${row.escalation}`,
      );
    }
    this.escalations.set(row.escalation, row);
  }

  async deleteEscalation(id: EscalationId): Promise<void> {
    this.escalations.delete(id);
  }

  async putCore(row: PersistedCoreInstance): Promise<void> {
    // Merge only `engineState` + `ambientGenerics` into an existing row (see `RowStore.putCore`); a
    // `null` substitution leaves the stored one untouched, matching the DB's skipped column.
    const existing = this.coreRows.get(row.instanceId);
    this.coreRows.set(
      row.instanceId,
      existing === undefined
        ? row
        : {
            ...existing,
            engineState: row.engineState,
            ambientGenerics: row.ambientGenerics ?? existing.ambientGenerics,
          },
    );
  }

  async replaceThreads(instance: InstanceId, rows: PersistedThread[]): Promise<void> {
    this.threadRows.set(instance, rows);
  }

  async putExternalCall(row: PersistedExternalCallRow): Promise<void> {
    this.externalRows.set(row.instanceId, row);
  }

  async putRoute(route: PersistedCapabilityRoute): Promise<void> {
    // Insert-if-absent: the route is immutable, so a re-register is a no-op (see `RowStore.putRoute`).
    if (!this.routes.has(route.token)) this.routes.set(route.token, route);
  }

  async putScope(row: PersistedScope): Promise<void> {
    this.scopeRows.set(row.scopeId, row);
  }

  async deleteScope(scopeId: number): Promise<void> {
    this.scopeRows.delete(scopeId);
  }

  async putBlob(row: PersistedBlob): Promise<void> {
    // Merge only the owner into an existing row (see `RowStore.putBlob`).
    const existing = this.blobRows.get(row.blobId);
    this.blobRows.set(
      row.blobId,
      existing === undefined ? row : { ...existing, ownerInstanceId: row.ownerInstanceId },
    );
  }

  async deleteBlob(id: BlobId): Promise<void> {
    this.blobRows.delete(id);
  }

  async insertRun(row: PersistedRun): Promise<void> {
    if (this.runs.has(row.run)) return;
    this.runs.set(row.run, {
      ...row,
      state: "running",
      result: null,
      errorMessage: null,
      cancelReason: null,
      completedAt: null,
    });
  }

  async updateRun(run: InstanceId, patch: RunOutcomePatch): Promise<void> {
    const stored = this.runs.get(run);
    if (stored === undefined) return;
    stored.state = patch.state;
    stored.result = patch.result;
    stored.errorMessage = patch.errorMessage;
    if (patch.completedAt !== undefined) stored.completedAt = patch.completedAt;
    if (patch.cancelReason !== undefined) stored.cancelReason = patch.cancelReason;
  }

  async insertAudit(row: PersistedRunEscalationAudit): Promise<void> {
    const exists = this.audits.some(
      (audit) => audit.run === row.run && audit.escalation === row.escalation,
    );
    if (!exists) this.audits.push(row);
  }

  async deleteOutbox(seq: OutboxSeq): Promise<void> {
    this.outbox.delete(seq);
  }

  async insertOutbox(rows: OutboxMessage[]): Promise<void> {
    for (const row of rows) this.outbox.set(row.seq, row);
  }

  async appendJournal(events: ExternalEvent[]): Promise<void> {
    this.journal.push(...events);
  }

  async delegationsFrom(from: ReactorName): Promise<PersistedDelegation[]> {
    return [...this.delegations.values()].filter((row) => row.fromReactor === from);
  }

  async openEscalations(filter: {
    from?: ReactorName;
    to?: ReactorName;
  }): Promise<PersistedEscalation[]> {
    return [...this.escalations.values()].filter(
      (row) =>
        (filter.from === undefined || row.fromReactor === filter.from) &&
        (filter.to === undefined || row.toReactor === filter.to),
    );
  }

  async coreInstances(): ReturnType<RowStore["coreInstances"]> {
    const rows: Awaited<ReturnType<RowStore["coreInstances"]>> = [];
    for (const [id, envelope] of this.envelopes) {
      const core = this.coreRows.get(id);
      if (envelope.kind !== "core" || core === undefined) continue;
      rows.push({
        id,
        delegationId: envelope.delegationId,
        callerReactor: envelope.callerReactor,
        runId: envelope.runId,
        status: envelope.status,
        core,
      });
    }
    return rows;
  }

  async threads(): Promise<PersistedThread[]> {
    return [...this.threadRows.values()].flat();
  }

  async scopes(): Promise<PersistedScope[]> {
    return [...this.scopeRows.values()];
  }

  async blobs(): Promise<PersistedBlob[]> {
    return [...this.blobRows.values()];
  }

  async externalCalls(
    kind: Parameters<RowStore["externalCalls"]>[0],
  ): ReturnType<RowStore["externalCalls"]> {
    const rows: Awaited<ReturnType<RowStore["externalCalls"]>> = [];
    for (const [id, envelope] of this.envelopes) {
      const extension = this.externalRows.get(id);
      if (envelope.kind !== kind || extension === undefined) continue;
      rows.push({
        instance: id,
        delegation: envelope.delegationId,
        caller: envelope.callerReactor,
        run: envelope.runId,
        status: extension.status,
        extension: extension.extension,
      });
    }
    return rows;
  }

  async pendingOutbox(): Promise<OutboxMessage[]> {
    return [...this.outbox.values()];
  }
}

export class StoringPersistence implements Persistence {
  private readonly store = new MapRowStore();

  /** How many commits (transactions) ran — what batching tests assert (one batch = one commit). */
  commitCount = 0;

  async load(_projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    await body(storeLoader(this.store));
  }

  async transaction(
    _projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    this.commitCount += 1;
    await body(storeTx(this.store));
  }

  // ─── test helpers (reads over the twin's maps; value-bearing rows unseal back to their warm form) ──

  /** Test helper: how many *engine* instances are currently live — i.e. `core`-kind instances. The permanent
   *  `api` root and any in-flight external calls are excluded (they are not engine activations); the engine
   *  load filters by `kind = 'core'` the same way. */
  instanceCount(): number {
    let count = 0;
    for (const envelope of this.store.envelopes.values()) {
      if (envelope.kind === "core") count += 1;
    }
    return count;
  }

  /** Test helper: how many live instance envelopes of `kind` remain — e.g. `ffi` calls, to assert a
   *  recovery left no orphaned external work behind. */
  envelopeCount(kind: string): number {
    let count = 0;
    for (const envelope of this.store.envelopes.values()) {
      if (envelope.kind === kind) count += 1;
    }
    return count;
  }

  /** Test helper: how many produced events are still undrained in the outbox (0 once a project quiesces). */
  outboxSize(): number {
    return this.store.outbox.size;
  }

  /** Test helper: how many persisted thread rows are live across every instance — one half of a
   *  flat-growth assertion (a `forever` loop must not accumulate a row per iteration). */
  threadCount(): number {
    let count = 0;
    for (const rows of this.store.threadRows.values()) count += rows.length;
    return count;
  }

  /** Test helper: how many persisted scopes are live — the other half of the flat-growth assertion
   *  (each completed iteration's scope must be reclaimed, not parked). */
  scopeCount(): number {
    return this.store.scopeRows.size;
  }

  /** Test helper: the journaled trace of one run, in production order (unsealed back to its warm form). */
  journalFor(run: InstanceId): ExternalEvent[] {
    return this.store.journal
      .filter((event) => event.run === run)
      .map((event) => unsealFromStorage(event));
  }

  /** Test helper: seed the outbox directly, simulating an event produced just before a crash. */
  seedOutbox(message: OutboxMessage): void {
    this.store.outbox.set(message.seq, message);
  }

  /** Test helper: seed a live delegation row directly, simulating one the caller persisted just before a
   *  crash (the caller opens its delegation row atomically with producing the `delegate`, so a recovered
   *  actor sees both — the row in `liveDelegations`, the event in the outbox). */
  seedDelegation(
    delegation: DelegationId,
    row: { caller: InstanceId; fromReactor: ReactorName; toReactor: ReactorName },
  ): void {
    this.store.delegations.set(delegation, { delegation, ...row, state: "running" });
  }

  /** Test helper: seed a live run record directly, simulating the `runs` row `startRun` persisted (atomically
   *  with the run delegation + its `delegate`) just before a crash, so a recovered actor can update its
   *  outcome. Starts `running`. */
  seedRun(run: InstanceId, launch: Omit<PersistedRun, "run">): void {
    this.store.runs.set(run, {
      run,
      ...launch,
      state: "running",
      result: null,
      errorMessage: null,
      cancelReason: null,
      completedAt: null,
    });
  }

  /** Test helper: the stored Layer 1 state of a delegation (for asserting it is live / deleted on terminal). */
  peekDelegation(delegation: DelegationId): PersistedDelegation | undefined {
    return this.store.delegations.get(delegation);
  }

  /** Test helper: the run's single live delegation row (the one its run instance issued), or undefined once
   *  the run is terminal — the storing twin of the api reactor's own caller-owned lookup. */
  runDelegationOf(run: InstanceId): PersistedDelegation | undefined {
    for (const row of this.store.delegations.values()) {
      if (row.caller === run) return row;
    }
    return undefined;
  }

  /** Test helper: the stored `runs` metadata sidecar (+ cancel reason) for a run, its result unsealed. */
  peekRun(run: InstanceId): StoredRun | undefined {
    const stored = this.store.runs.get(run);
    if (stored === undefined) return undefined;
    return { ...stored, result: unsealFromStorage(stored.result) };
  }

  /** Test helper: the resolved-escalation audit rows recorded for a run, in resolution order, unsealed. An
   *  answered user-facing escalation carries its answer; a failed / cancelled one a `null` answer. */
  auditsFor(run: InstanceId): PersistedRunEscalationAudit[] {
    return this.store.audits
      .filter((audit) => audit.run === run)
      .map((audit) => ({
        ...audit,
        question: unsealFromStorage(audit.question),
        answer: unsealFromStorage(audit.answer),
      }));
  }

  /** Test helper: how many durable escalation rows are live across the whole project — the leak-freedom
   *  assertion (every escalation, failure or answerable, is retired / cascaded once resolved, so a quiesced
   *  project holds zero). */
  escalationCount(): number {
    return this.store.escalations.size;
  }
}
