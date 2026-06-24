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
import type { DelegationId, InstanceId, ProjectId } from "../ids.js";
import type { TurnCommit } from "./turn-commit.js";

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
}

export interface Persistence {
  /** Load a project's persisted instances + scopes + live delegation edges to reactivate its warm actor. */
  loadProject(projectId: ProjectId): Promise<ProjectSnapshot>;
  /** Commit one turn atomically: its Layer 2 (persist the instance's graph, or drop it) together with the
   *  Layer 1 entity transitions it implies. */
  commitTurn(projectId: ProjectId, commit: TurnCommit): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so nothing persists and nothing loads. */
export class InMemoryPersistence implements Persistence {
  async loadProject(): Promise<ProjectSnapshot> {
    return { instances: {}, scopes: {}, nextScopeId: 0, delegations: {} };
  }
  async commitTurn(): Promise<void> {}
}
