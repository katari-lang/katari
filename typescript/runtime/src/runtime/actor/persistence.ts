// The persistence seam. The design persists an instance's graph after its internal queue drains (the
// turn boundary: "DB reflection after the internal queue is empty"). v0.1.0's in-memory core keeps the
// warm `ProjectStore` as the source of truth and persists nothing; a drizzle-backed implementation drops
// in behind this interface (row-per-thread / row-per-scope, instance metadata, blob ledger) without the
// engine or actor changing.

import type { ProjectStore } from "../engine/types.js";
import type { ProjectId } from "../ids.js";

export interface Persistence {
  /** Flush the project's dirty engine graph at a turn boundary (the internal queue having drained). */
  persistTurn(projectId: ProjectId, store: ProjectStore): Promise<void>;
}

/** The seam implementation: the warm store is the truth, so a turn persists nothing. */
export class InMemoryPersistence implements Persistence {
  async persistTurn(_projectId: ProjectId, _store: ProjectStore): Promise<void> {
    // Intentionally empty — the in-memory ProjectStore already holds the committed state.
  }
}
