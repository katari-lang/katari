// An in-memory `Persistence` that actually *stores* the serialised rows (unlike `InMemoryPersistence`'s
// no-op), so the recovery path — commit at the turn boundary, then reload + reactivate in a fresh actor —
// is exercisable without Postgres. The DB-backed `DbPersistence` mirrors this against real tables; keeping
// a faithful in-memory twin lets recovery be unit-tested deterministically.
//
// One turn = one `transaction`: the substrate hands the reactor + outbox a `PersistenceTx` whose methods
// mutate these maps. There is no real atomicity to enforce here (a single-threaded twin), so the tx just
// applies each write as it is called; the FK / cascade order is the caller's (the reactor writes its instance
// before the rows that reference it, and `dropInstance` cascades last).

import { type DelegationState, isLiveDelegationState } from "../../db/tables/execution.js";
import type { DelegateTarget } from "../event/types.js";
import type { DelegationId, EscalationId, InstanceId, OutboxSeq, ProjectId } from "../ids.js";
import type { Value } from "../value/types.js";
import type {
  OutboxMessage,
  PersistedDelegation,
  PersistedOpenEscalation,
  PersistedRun,
  PersistedRunEscalationAudit,
  Persistence,
  PersistenceTx,
  ProjectSnapshot,
} from "./persistence.js";
import {
  deserializeProject,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
} from "./persistence-codec.js";

/** A stored Layer 1 delegation row (the durable caller→child record + its lifecycle). */
interface StoredDelegation {
  caller: InstanceId;
  target: DelegateTarget;
  argument: Value | null;
  state: DelegationState;
  result: Value | null;
  errorMessage: string | null;
}

interface StoredEscalation {
  raiser: InstanceId;
  state: "open" | "answered";
  request: string;
  argument: Value | null;
  answer: Value | null;
}

/** A stored run metadata sidecar + the API's cancel reason (the run's outcome is its delegation, not this). */
interface StoredRun extends PersistedRun {
  cancelReason: string | null;
}

export class StoringPersistence implements Persistence {
  /** Layer 2, per instance: the instance row and its whole thread tree (replaced wholesale each turn). */
  private readonly instances = new Map<InstanceId, PersistedInstance>();
  private readonly threads = new Map<InstanceId, PersistedThread[]>();
  /** Scopes by id with their owner — cascaded on the owner's drop, mirroring the `scopes` table's FK. */
  private readonly scopes = new Map<number, PersistedScope>();
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

  async ensureApiRoot(): Promise<void> {
    // No FK to satisfy here (the in-memory twin enforces none), and the warm actor recreates the api root
    // in its store on every reactivation, so there is nothing to persist. Present for interface parity.
  }

  async loadProject(_projectId: ProjectId): Promise<ProjectSnapshot> {
    const engine = deserializeProject(
      [...this.instances.values()],
      [...this.threads.values()].flat(),
      [...this.scopes.values()],
    );
    const liveDelegations: PersistedDelegation[] = [];
    for (const [delegation, row] of this.delegations) {
      // Only live (running / cancelling) rows carry routing; finished ones are history.
      if (isLiveDelegationState(row.state)) {
        liveDelegations.push({
          delegation,
          caller: row.caller,
          target: row.target,
          argument: row.argument,
          state: row.state,
          result: row.result,
          errorMessage: row.errorMessage,
        });
      }
    }
    const openEscalations: PersistedOpenEscalation[] = [];
    for (const [escalation, row] of this.escalations) {
      if (row.state === "open") {
        openEscalations.push({
          escalation,
          raiser: row.raiser,
          request: row.request,
          argument: row.argument,
        });
      }
    }
    return {
      ...engine,
      liveDelegations,
      openEscalations,
      pendingOutbox: [...this.outbox.values()],
    };
  }

  async transaction(
    _projectId: ProjectId,
    body: (tx: PersistenceTx) => Promise<void>,
  ): Promise<void> {
    await body(this.tx());
  }

  /** The per-turn write surface over the twin's maps (mutating in call order). */
  private tx(): PersistenceTx {
    return {
      putDelegation: async (row) => {
        this.delegations.set(row.delegation, {
          caller: row.caller,
          target: row.target,
          argument: row.argument,
          state: row.state,
          result: row.result,
          errorMessage: row.errorMessage,
        });
      },
      putEscalation: async (row) => {
        this.escalations.set(row.escalation, {
          raiser: row.raiser,
          state: row.state,
          request: row.request,
          argument: row.argument,
          answer: row.answer,
        });
      },
      putInstance: async (serialized) => {
        this.instances.set(serialized.instance.id, serialized.instance);
        this.threads.set(serialized.instance.id, serialized.threads);
      },
      putScope: async (scope) => {
        this.scopes.set(scope.scopeId, scope);
      },
      deleteScope: async (scopeId) => {
        this.scopes.delete(scopeId);
      },
      dropInstance: async (instanceId) => {
        this.dropInstance(instanceId);
      },
      consumeOutbox: async (seq) => {
        this.outbox.delete(seq);
      },
      produceOutbox: async (messages) => {
        for (const message of messages) this.outbox.set(message.seq, message);
      },
      putRun: async (run) => {
        this.runs.set(run.run, { ...run, cancelReason: null });
      },
      setRunCancelReason: async (run, reason) => {
        const stored = this.runs.get(run);
        if (stored !== undefined) stored.cancelReason = reason;
      },
      putRunEscalationAudit: async (audit) => {
        this.audits.push(audit);
      },
    };
  }

  private dropInstance(instanceId: InstanceId): void {
    this.instances.delete(instanceId);
    this.threads.delete(instanceId);
    for (const [id, scope] of this.scopes) {
      if (scope.ownerInstanceId === instanceId) this.scopes.delete(id);
    }
    // Cascade the entities this instance owns (issued delegations / raised escalations), like the FKs.
    for (const [id, row] of this.delegations) {
      if (row.caller === instanceId) this.delegations.delete(id);
    }
    for (const [id, row] of this.escalations) {
      if (row.raiser === instanceId) this.escalations.delete(id);
    }
  }

  /** Test helper: how many instances currently have live Layer 2. */
  instanceCount(): number {
    return this.instances.size;
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
    row: { caller: InstanceId; target: DelegateTarget; argument: Value | null },
  ): void {
    this.delegations.set(delegation, {
      caller: row.caller,
      target: row.target,
      argument: row.argument,
      state: "running",
      result: null,
      errorMessage: null,
    });
  }

  /** Test helper: the stored Layer 1 state of a delegation (for asserting a run's durable outcome). */
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
