// An in-memory `Persistence` that actually *stores* the serialised rows (unlike `InMemoryPersistence`'s
// no-op), so the recovery path — commit at the turn boundary, then reload + reactivate in a fresh actor —
// is exercisable without Postgres. The DB-backed `DbPersistence` mirrors this against real tables; keeping
// a faithful in-memory twin lets recovery be unit-tested deterministically.

import { type DelegationState, isLiveDelegationState } from "../../db/tables/execution.js";
import type { DelegationId, EscalationId, InstanceId, OutboxSeq, ProjectId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { Persistence, ProjectSnapshot } from "./persistence.js";
import {
  deserializeProject,
  type PersistedInstance,
  type PersistedScope,
  type PersistedThread,
  serializeInstance,
} from "./persistence-codec.js";
import type { EntityTransition, OutboxMessage, TurnCommit } from "./turn-commit.js";

/** A stored Layer 1 delegation edge (the durable parent→child record + its lifecycle). `live` is true for
 *  running / cancelling delegations (which still route) and false once done / gone (history only). */
interface StoredDelegation {
  caller: InstanceId;
  state: DelegationState;
  result?: Value;
  errorMessage?: string;
}

interface StoredEscalation {
  raiser: InstanceId;
  state: "open" | "answered";
  request: string;
  argument: Value | null;
}

export class StoringPersistence implements Persistence {
  /** Layer 2, per instance: the instance row and its whole thread tree (replaced wholesale each turn). */
  private readonly instances = new Map<InstanceId, PersistedInstance>();
  private readonly threads = new Map<InstanceId, PersistedThread[]>();
  /** Scopes by id with their owner — cascaded on the owner's drop, mirroring the `scopes` table's FK. A
   *  scope that ascended to a new owner is re-keyed here by that owner's next persist. */
  private readonly scopes = new Map<number, PersistedScope>();
  /** Layer 1 entities. Cascaded with their owner on `drop` (a delegation with its caller, an escalation
   *  with its raiser), matching the tables' `ON DELETE CASCADE`. */
  private readonly delegations = new Map<DelegationId, StoredDelegation>();
  private readonly escalations = new Map<EscalationId, StoredEscalation>();
  /** Layer 3: the transactional outbox (produced-but-not-consumed events), insertion-ordered. */
  private readonly outbox = new Map<OutboxSeq, OutboxMessage>();

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
    const delegations: Record<DelegationId, InstanceId> = {};
    for (const [id, edge] of this.delegations) {
      // Only live (running / cancelling) edges carry routing; finished ones are history.
      if (isLiveDelegationState(edge.state)) {
        delegations[id] = edge.caller;
      }
    }
    const openEscalations: ProjectSnapshot["openEscalations"] = [];
    for (const [id, edge] of this.escalations) {
      if (edge.state === "open") {
        openEscalations.push({
          escalation: id,
          raiser: edge.raiser,
          request: edge.request,
          argument: edge.argument,
        });
      }
    }
    return { ...engine, delegations, openEscalations, pendingOutbox: [...this.outbox.values()] };
  }

  async commitTurn(projectId: ProjectId, commit: TurnCommit): Promise<void> {
    // Layer 3 (transactional outbox): consume the inbound row, produce the outbound ones — together with
    // Layer 1 / Layer 2, so a crash neither loses an in-flight event nor double-delivers a consumed one.
    if (commit.consumed !== null) this.outbox.delete(commit.consumed);
    for (const message of commit.produced) this.outbox.set(message.seq, message);
    // Layer 1: a `delegation-open` must precede the child instance that references it (FK order).
    for (const transition of commit.transitions) this.applyTransition(transition);
    // Layer 2: persist the instance's graph, drop it (cascading its threads / scopes / entities), or none
    // (an api-root turn carries no engine continuation).
    switch (commit.layer2.kind) {
      case "none":
        return;
      case "drop":
        this.dropInstance(commit.instanceId);
        return;
      case "persist": {
        const serialized = serializeInstance(
          projectId,
          commit.layer2.instance,
          commit.layer2.ownedScopes,
        );
        this.instances.set(serialized.instance.id, serialized.instance);
        this.threads.set(serialized.instance.id, serialized.threads);
        for (const scope of serialized.scopes) this.scopes.set(scope.scopeId, scope);
        return;
      }
    }
  }

  private applyTransition(transition: EntityTransition): void {
    switch (transition.kind) {
      case "delegation-open":
        this.delegations.set(transition.delegation, {
          caller: transition.caller,
          state: "running",
        });
        break;
      case "delegation-done": {
        // Terminal states are sticky — only a live delegation moves to a terminal one.
        const edge = this.delegations.get(transition.delegation);
        if (edge !== undefined && isLiveDelegationState(edge.state)) {
          edge.state = "done";
          edge.result = transition.result;
        }
        break;
      }
      case "delegation-cancelling": {
        // `cancelling` only from `running` (never resurrecting a terminal or re-cancelling).
        const edge = this.delegations.get(transition.delegation);
        if (edge !== undefined && edge.state === "running") edge.state = "cancelling";
        break;
      }
      case "delegation-gone": {
        const edge = this.delegations.get(transition.delegation);
        if (edge !== undefined && isLiveDelegationState(edge.state)) edge.state = "gone";
        break;
      }
      case "delegation-failed": {
        const edge = this.delegations.get(transition.delegation);
        if (edge !== undefined && isLiveDelegationState(edge.state)) {
          edge.state = "failed";
          edge.errorMessage = transition.errorMessage;
        }
        break;
      }
      case "escalation-open":
        this.escalations.set(transition.escalation, {
          raiser: transition.raiser,
          state: "open",
          request: transition.request,
          argument: transition.argument,
        });
        break;
      case "escalation-answered": {
        const edge = this.escalations.get(transition.escalation);
        if (edge !== undefined) edge.state = "answered";
        break;
      }
    }
  }

  private dropInstance(instanceId: InstanceId): void {
    this.instances.delete(instanceId);
    this.threads.delete(instanceId);
    for (const [id, scope] of this.scopes) {
      if (scope.ownerInstanceId === instanceId) this.scopes.delete(id);
    }
    // Cascade the entities this instance owns (issued delegations / raised escalations), like the FKs.
    for (const [id, edge] of this.delegations) {
      if (edge.caller === instanceId) this.delegations.delete(id);
    }
    for (const [id, edge] of this.escalations) {
      if (edge.raiser === instanceId) this.escalations.delete(id);
    }
  }

  /** Test helper: how many instances currently have live Layer 2. */
  instanceCount(): number {
    return this.instances.size;
  }

  /** Test helper: how many produced events are still undrained in the outbox (0 once a project quiesces —
   *  every produced event was consumed). */
  outboxSize(): number {
    return this.outbox.size;
  }

  /** Test helper: seed the outbox directly, simulating an event produced just before a crash (so a fresh
   *  actor must replay it). */
  seedOutbox(message: OutboxMessage): void {
    this.outbox.set(message.seq, message);
  }

  /** Test helper: the stored Layer 1 state of a delegation (for asserting a run's durable outcome). */
  peekDelegation(delegation: DelegationId): StoredDelegation | undefined {
    return this.delegations.get(delegation);
  }
}
