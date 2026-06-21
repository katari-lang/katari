// The persistence boundary. The design persists an instance's graph after its internal queue drains
// (the turn boundary: "DB reflection after the internal queue is empty"). Engine recovery needs only
// three row sets — instances (with an `engine_state` JSON of the bookkeeping), threads, and scopes —
// because the actor's routing maps are all derivable from them (a `pendingDelegations` key names a
// delegation's caller, `delegationId` its child, an `escalationContinuations` key its raiser).
//
// v0.1.0 ships two implementations: an in-memory no-op (the warm store is the truth) and a drizzle-backed
// one (`DbPersistence`). The warm per-project actor loads once on first use and write-through persists
// each turn; a transient instance that completes within its spawn turn never touches the DB.

import type { Instance, ProjectStore, Scope } from "../engine/types.js";
import type { InstanceId, ProjectId } from "../ids.js";

/** A project's reconstructed engine state (the actor rebuilds its routing maps from the instances). */
export interface ProjectSnapshot {
  instances: ProjectStore["instances"];
  scopes: ProjectStore["scopes"];
  nextScopeId: number;
}

export interface Persistence {
  /** Load a project's persisted instances + scopes to reactivate its warm actor (recovery). */
  loadProject(projectId: ProjectId): Promise<ProjectSnapshot>;
  /** Write-through a still-running instance's graph (its row + engine_state, threads, owned scopes). */
  persistInstance(projectId: ProjectId, instance: Instance, ownedScopes: Scope[]): Promise<void>;
  /** Drop a completed / terminated instance (cascade removes its threads, scopes, …). */
  dropInstance(projectId: ProjectId, instanceId: InstanceId): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so nothing persists and nothing loads. */
export class InMemoryPersistence implements Persistence {
  async loadProject(): Promise<ProjectSnapshot> {
    return { instances: {}, scopes: {}, nextScopeId: 0 };
  }
  async persistInstance(): Promise<void> {}
  async dropInstance(): Promise<void> {}
}
