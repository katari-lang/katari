// An in-memory `Persistence` that actually *stores* the serialised rows (unlike `InMemoryPersistence`'s
// no-op), so the recovery path — commit at the turn boundary, then reload + reactivate in a fresh actor —
// is exercisable without Postgres. The DB-backed `DbPersistence` mirrors this against real tables; keeping
// a faithful in-memory twin lets recovery be unit-tested deterministically.
//
// One turn = one `transaction`: the substrate hands the reactor + outbox a `PersistenceTx` whose methods
// mutate these maps. There is no real atomicity to enforce here (a single-threaded twin), so the tx just
// applies each write as it is called; the FK / cascade order is the caller's (the reactor writes its instance
// before the rows that reference it, and `dropInstance` cascades last).

import {
  type DelegationState,
  isLiveDelegationState,
  type RunState,
} from "../../db/tables/execution.js";
import type { DelegateTarget, ReactorName } from "../event/types.js";
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
  BaseTx,
  Loader,
  OutboxMessage,
  PersistedDelegation,
  PersistedFfiInstance,
  PersistedFfiInstanceRow,
  PersistedOpenEscalation,
  PersistedRun,
  PersistedRunEscalationAudit,
  Persistence,
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

/** A stored Layer 1 delegation row (the durable caller→child record + its lifecycle + its from/to reactors). */
interface StoredDelegation {
  caller: InstanceId;
  fromReactor: ReactorName;
  toReactor: ReactorName;
  target: DelegateTarget;
  argument: Value | null;
  state: DelegationState;
  result: Value | null;
  errorMessage: string | null;
}

interface StoredEscalation {
  raiser: InstanceId;
  fromReactor: ReactorName;
  toReactor: ReactorName;
  delegation: DelegationId;
  state: "open" | "answered";
  request: string;
  argument: Value | null;
  answer: Value | null;
}

/** A stored run record: its launch metadata plus its durable state / outcome (the run delegation row is
 *  deleted on terminal, so this is the run's source of truth). */
interface StoredRun extends PersistedRun {
  state: RunState;
  result: Value | null;
  errorMessage: string | null;
  cancelReason: string | null;
  completedAt: Date | null;
}

export class StoringPersistence implements Persistence {
  /** Layer 2, per instance: the generic envelope, plus the kind-specific extension (`core` engine state /
   *  `ffi` call state) and — for core — its whole thread tree (replaced wholesale each turn). */
  private readonly envelopes = new Map<InstanceId, PersistedInstanceEnvelope>();
  private readonly coreInstanceRows = new Map<InstanceId, PersistedCoreInstance>();
  private readonly ffiInstanceRows = new Map<InstanceId, PersistedFfiInstanceRow>();
  private readonly threads = new Map<InstanceId, PersistedThread[]>();
  /** Scopes by id with their owner — cascaded on the owner's drop, mirroring the `scopes` table's FK. */
  private readonly scopes = new Map<number, PersistedScope>();
  /** Blob ownership + descriptor rows — cascaded on the owner's drop, mirroring the `blobs` table's FK. */
  private readonly blobRows = new Map<BlobId, PersistedBlob>();
  /** Layer 1 entities. Cascaded with their owner on `dropInstance` (a delegation with its caller, an
   *  escalation with its raiser), matching the tables' `ON DELETE CASCADE`. */
  private readonly delegations = new Map<DelegationId, StoredDelegation>();
  private readonly escalations = new Map<EscalationId, StoredEscalation>();
  /** Layer 3: the transactional outbox (produced-but-not-consumed events), insertion-ordered. */
  private readonly outbox = new Map<OutboxSeq, OutboxMessage>();
  /** The API's run-metadata sidecar + answered-escalation history (DB-SoT projections; reads go straight to
   *  these, not through the warm actor). */
  private readonly runs = new Map<DelegationId, StoredRun>();
  private readonly audits: PersistedRunEscalationAudit[] = [];

  async load(_projectId: ProjectId, body: (loader: Loader) => Promise<void>): Promise<void> {
    await body(this.loader());
  }

  /** The per-owner read surface over the twin's maps — each reactor reads through `loader.<name>`. The
   *  reactor-parameterized queries (delegations / open escalations) are shared helpers the ports bind. */
  private loader(): Loader {
    const delegationsFrom = (from: ReactorName): PersistedDelegation[] => {
      const result: PersistedDelegation[] = [];
      for (const [delegation, row] of this.delegations) {
        // Only live (running / cancelling) rows carry routing; finished ones are history.
        if (row.fromReactor === from && isLiveDelegationState(row.state)) {
          result.push({
            delegation,
            caller: row.caller,
            fromReactor: row.fromReactor,
            toReactor: row.toReactor,
            target: row.target,
            argument: row.argument,
            state: row.state,
            result: row.result,
            errorMessage: row.errorMessage,
          });
        }
      }
      return result;
    };
    const openEscalationsWhere = (filter: {
      from?: ReactorName;
      to?: ReactorName;
    }): PersistedOpenEscalation[] => {
      const result: PersistedOpenEscalation[] = [];
      for (const [escalation, row] of this.escalations) {
        if (row.state !== "open") continue;
        if (filter.from !== undefined && row.fromReactor !== filter.from) continue;
        if (filter.to !== undefined && row.toReactor !== filter.to) continue;
        result.push({
          escalation,
          raiser: row.raiser,
          fromReactor: row.fromReactor,
          toReactor: row.toReactor,
          delegation: row.delegation,
          request: row.request,
          argument: row.argument,
        });
      }
      return result;
    };
    return {
      base: {
        delegations: async (from) => delegationsFrom(from),
        raisedEscalations: async (from) => openEscalationsWhere({ from }),
      },
      core: {
        engine: async () => {
          // Join each `core` envelope to its extension, the shape `deserializeProject` rebuilds from.
          const coreInstances: PersistedInstance[] = [];
          for (const [id, envelope] of this.envelopes) {
            const ext = this.coreInstanceRows.get(id);
            if (envelope.kind !== "core" || ext === undefined) continue;
            coreInstances.push({
              id,
              delegationId: envelope.delegationId,
              target: ext.target,
              snapshotId: ext.snapshotId,
              status: envelope.status,
              ambientGenerics: ext.ambientGenerics,
              engineState: ext.engineState,
            });
          }
          return deserializeProject(
            coreInstances,
            [...this.threads.values()].flat(),
            [...this.scopes.values()],
            [...this.blobRows.values()],
          );
        },
      },
      api: {
        answerableEscalations: async () => openEscalationsWhere({ to: "api" }),
      },
      ffi: {
        instances: async () => {
          const result: PersistedFfiInstance[] = [];
          for (const [id, envelope] of this.envelopes) {
            const ext = this.ffiInstanceRows.get(id);
            if (envelope.kind !== "ffi" || ext === undefined || envelope.delegationId === null)
              continue;
            result.push({
              delegation: envelope.delegationId,
              instance: id,
              snapshot: ext.snapshotId,
              key: ext.key,
              argument: ext.argument,
              caller: ext.callerReactor,
              status: ext.status,
            });
          }
          return result;
        },
      },
      outbox: {
        pending: async () => [...this.outbox.values()],
      },
    };
  }

  async transaction(
    _projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    await body(this.tx());
  }

  /** The per-turn write surface over the twin's maps (mutating in call order), split into per-owner ports.
   *  The `base` port's generic-row writers are defined once here. */
  private tx(): PersistenceTx {
    const putInstanceEnvelope: BaseTx["putInstanceEnvelope"] = async (envelope) => {
      this.envelopes.set(envelope.id, envelope);
    };
    const putDelegation: BaseTx["putDelegation"] = async (row) => {
      this.delegations.set(row.delegation, {
        caller: row.caller,
        fromReactor: row.fromReactor,
        toReactor: row.toReactor,
        target: row.target,
        argument: row.argument,
        state: row.state,
        result: row.result,
        errorMessage: row.errorMessage,
      });
    };
    const dropInstance = async (instanceId: InstanceId) => {
      this.dropInstance(instanceId);
    };
    return {
      base: {
        putInstanceEnvelope,
        putDelegation,
        dropInstance,
        deleteDelegation: async (delegation) => {
          this.delegations.delete(delegation);
        },
        deleteEscalation: async (escalation) => {
          this.escalations.delete(escalation);
        },
        putEscalation: async (row) => {
          this.escalations.set(row.escalation, {
            raiser: row.raiser,
            fromReactor: row.fromReactor,
            toReactor: row.toReactor,
            delegation: row.delegation,
            state: row.state,
            request: row.request,
            argument: row.argument,
            answer: row.answer,
          });
        },
      },
      core: {
        putCoreInstance: async (serialized) => {
          this.coreInstanceRows.set(serialized.instance.instanceId, serialized.instance);
          this.threads.set(serialized.instance.instanceId, serialized.threads);
        },
      },
      api: {
        putRun: async (run) => {
          this.runs.set(run.run, {
            ...run,
            state: "running",
            result: null,
            errorMessage: null,
            cancelReason: null,
            completedAt: null,
          });
        },
        setRunOutcome: async (outcome) => {
          const stored = this.runs.get(outcome.run);
          if (stored === undefined) return;
          stored.state = outcome.state;
          stored.result = outcome.result;
          stored.errorMessage = outcome.errorMessage;
        },
        setRunCancelReason: async (run, reason) => {
          const stored = this.runs.get(run);
          if (stored !== undefined) stored.cancelReason = reason;
        },
        putRunEscalationAudit: async (audit) => {
          this.audits.push(audit);
        },
      },
      ffi: {
        putFfiInstance: async (row) => {
          this.ffiInstanceRows.set(row.instanceId, row);
        },
      },
      pool: {
        putScope: async (scope) => {
          this.scopes.set(scope.scopeId, scope);
        },
        deleteScope: async (scopeId) => {
          this.scopes.delete(scopeId);
        },
        putBlob: async (blob) => {
          this.blobRows.set(blob.blobId, blob);
        },
        dropBlob: async (blobId) => {
          this.blobRows.delete(blobId);
        },
      },
      outbox: {
        consumeOutbox: async (seq) => {
          this.outbox.delete(seq);
        },
        produceOutbox: async (messages) => {
          for (const message of messages) this.outbox.set(message.seq, message);
        },
      },
    };
  }

  private dropInstance(instanceId: InstanceId): void {
    // Drop the envelope and cascade the kind extensions keyed by it (mirroring the tables' ON DELETE CASCADE).
    this.envelopes.delete(instanceId);
    this.coreInstanceRows.delete(instanceId);
    this.ffiInstanceRows.delete(instanceId);
    this.threads.delete(instanceId);
    for (const [id, scope] of this.scopes) {
      if (scope.ownerInstanceId === instanceId) this.scopes.delete(id);
    }
    for (const [id, blob] of this.blobRows) {
      if (blob.ownerInstanceId === instanceId) this.blobRows.delete(id);
    }
    // Cascade the entities this instance owns (issued delegations / raised escalations), like the FKs.
    for (const [id, row] of this.delegations) {
      if (row.caller === instanceId) this.delegations.delete(id);
    }
    for (const [id, row] of this.escalations) {
      if (row.raiser === instanceId) this.escalations.delete(id);
    }
  }

  /** Test helper: how many *engine* instances are currently live — i.e. `core`-kind instances. The permanent
   *  `api` root and any in-flight `ffi` calls are excluded (they are not engine activations); the engine load
   *  filters by `kind = 'core'` the same way. */
  instanceCount(): number {
    let count = 0;
    for (const envelope of this.envelopes.values()) {
      if (envelope.kind === "core") count += 1;
    }
    return count;
  }

  /** Test helper: how many produced events are still undrained in the outbox (0 once a project quiesces). */
  outboxSize(): number {
    return this.outbox.size;
  }

  /** Test helper: seed the outbox directly, simulating an event produced just before a crash. */
  seedOutbox(message: OutboxMessage): void {
    this.outbox.set(message.seq, message);
  }

  /** Test helper: seed a live delegation row directly, simulating one the caller persisted just before a
   *  crash (the caller opens its delegation row atomically with producing the `delegate`, so a recovered
   *  actor sees both — the row in `liveDelegations`, the event in the outbox). */
  seedDelegation(
    delegation: DelegationId,
    row: {
      caller: InstanceId;
      fromReactor: ReactorName;
      toReactor: ReactorName;
      target: DelegateTarget;
      argument: Value | null;
    },
  ): void {
    this.delegations.set(delegation, {
      caller: row.caller,
      fromReactor: row.fromReactor,
      toReactor: row.toReactor,
      target: row.target,
      argument: row.argument,
      state: "running",
      result: null,
      errorMessage: null,
    });
  }

  /** Test helper: seed a live run record directly, simulating the `runs` row `startRun` persisted (atomically
   *  with the run delegation + its `delegate`) just before a crash, so a recovered actor can update its
   *  outcome. Starts `running`. */
  seedRun(run: DelegationId, launch: Omit<PersistedRun, "run">): void {
    this.runs.set(run, {
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
  peekDelegation(delegation: DelegationId): StoredDelegation | undefined {
    return this.delegations.get(delegation);
  }

  /** Test helper: the stored `runs` metadata sidecar (+ cancel reason) for a run. */
  peekRun(run: DelegationId): StoredRun | undefined {
    return this.runs.get(run);
  }

  /** Test helper: the answered-escalation audit rows recorded for a run, in answer order. */
  auditsFor(run: DelegationId): PersistedRunEscalationAudit[] {
    return this.audits.filter((audit) => audit.run === run);
  }
}
