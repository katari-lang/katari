// The persistence boundary. An instance's turn drains its internal queue, then commits at the turn
// boundary ("DB reflection after the internal queue is empty"). One turn = one atomic `commitTurn`: the
// turn's Layer 2 (engine continuation — its threads + owned scopes, or its drop) is written together with
// the Layer 1 entity transitions it implies (delegations / escalations state changes). Writing both in one
// transaction is what closes the gap a `DelegateThread` would otherwise open — referencing a delegation
// whose durable row had not been written yet.
//
// v0.1.0 ships three implementations: an in-memory no-op (`InMemoryPersistence` — the warm store is the
// truth), an in-memory *storing* twin (`StoringPersistence`, for recovery tests), and a drizzle-backed one
// (`DbPersistence`). The warm per-project actor loads once on first use and write-through commits each
// turn; a transient instance that completes within its spawn turn still commits (its Layer 1 edges), but
// its Layer 2 is dropped rather than persisted.

import type { ProjectStore } from "../engine/types.js";
import type { DelegationId, EscalationId, InstanceId, ProjectId } from "../ids.js";
import type { Value } from "../value/types.js";
import type { OutboxMessage, TurnCommit } from "./turn-commit.js";

/** A persisted open escalation (an `escalations` row still in the `open` state). The actor rehydrates the
 *  user-facing ones (those raised by a run root) into its open-escalation registry on reactivation. */
export interface PersistedOpenEscalation {
  escalation: EscalationId;
  raiser: InstanceId;
  request: string;
  argument: Value | null;
}

/** A project's reconstructed engine state (the actor rebuilds its routing maps from this on reactivation).
 *
 *  Routing is recovered from two complementary sources. A surviving `DelegateThread` names its delegation's
 *  caller (its own instance) — this covers a freshly-issued delegation whose child instance may not have
 *  been created yet. The `delegations` map (the live Layer 1 edges) covers the rest, in particular the api
 *  root's run delegations, which have no `DelegateThread` to rebuild from. An instance's own `delegationId`
 *  names its child (and, since the escalating child is the delegation's child, its escalation raiser). */
export interface ProjectSnapshot {
  instances: ProjectStore["instances"];
  scopes: ProjectStore["scopes"];
  nextScopeId: number;
  /** Live (running / cancelling) delegation edges: delegation id → its caller instance. Finished
   *  delegations (done / gone) are history and carry no live routing, so they are excluded here. */
  delegations: Record<DelegationId, InstanceId>;
  /** Open escalations (the `open` rows). The actor keeps the user-facing ones (raised by a run root) — a
   *  run suspended awaiting a user's answer must survive a restart. Inner-hop escalations recover with the
   *  engine threads (their relay state is Layer 2), so the actor ignores those here. */
  openEscalations: PersistedOpenEscalation[];
  /** Undrained outbox rows: events produced before the crash but not yet consumed. The actor replays them
   *  into its mailbox so an in-flight event (e.g. a completed child's `delegateAck`) is not lost. */
  pendingOutbox: OutboxMessage[];
}

export interface Persistence {
  /** Load a project's persisted instances + scopes + live delegation edges to reactivate its warm actor. */
  loadProject(projectId: ProjectId): Promise<ProjectSnapshot>;
  /** Durably ensure the project's permanent `api` management root exists as an `instances` row, so a run's
   *  `delegation-open` (whose caller is the api root) satisfies the `delegations.caller_instance_id` FK.
   *  Idempotent; a no-op for the in-memory seam (no FK to satisfy). Called once on reactivation, before any
   *  commit can reference the api root. */
  ensureApiRoot(projectId: ProjectId, apiRootId: InstanceId): Promise<void>;
  /** Commit one turn atomically: its Layer 2 (persist the instance's graph, or drop it) together with the
   *  Layer 1 entity transitions it implies. */
  commitTurn(projectId: ProjectId, commit: TurnCommit): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so nothing persists and nothing loads. */
export class InMemoryPersistence implements Persistence {
  async loadProject(): Promise<ProjectSnapshot> {
    return {
      instances: {},
      scopes: {},
      nextScopeId: 0,
      delegations: {},
      openEscalations: [],
      pendingOutbox: [],
    };
  }
  async ensureApiRoot(): Promise<void> {}
  async commitTurn(): Promise<void> {}
}
