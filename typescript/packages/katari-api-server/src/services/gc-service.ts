// Blob GC crash backstop (Phase G recovery half).
//
// The primary GC is incremental + single-owner: every ephemeral ref is owned
// by exactly one durable entity (a delegation while running, then a run /
// escalation), and CoreModule releases / hands its refs up at each shard's
// terminal. That handles the steady state with no global scan.
//
// This backstop reclaims the leftovers a CRASH can produce: a ref whose owning
// entity finished (or was force-deleted) but whose explicit release didn't run
// because the process died mid-tick. It drops every ref whose owner is no
// longer a live entity (delegations ∪ runs_audit ∪ escalations).
//
// SAFETY: it must run only when nothing is concurrently producing refs for the
// project — otherwise a ref produced after the live-owner snapshot was taken,
// but before the sweep's DELETE, would be wrongly collected. So it runs at BOOT
// (before the server accepts traffic). A periodic while-live sweep would have
// to run as a serialized quantum on the project actor; that is deferred.

import type { Logger } from "@katari-lang/runtime";
import type { ListOptions, ListResult, ProjectId, Storage } from "../storage/types.js";

export class GcService {
  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
  ) {}

  /** Boot-time backstop across every project. */
  async sweepAllProjects(): Promise<void> {
    for await (const projectId of this.eachProjectId()) {
      try {
        const live = await this.liveOwnerIds(projectId);
        const freed = await this.storage.values.sweepRefsWithDeadOwners(projectId, live);
        if (freed > 0) {
          this.logger.log("info", "gc: reclaimed orphaned blobs on boot", { projectId, freed });
        }
      } catch (err) {
        this.logger.log("warn", "gc: project sweep failed", {
          projectId,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }
  }

  /** Every id that is still a valid ref owner: live delegations, runs (their
   *  results outlive the delegation), and open/answered escalations. */
  private async liveOwnerIds(projectId: ProjectId): Promise<Set<string>> {
    const ids = new Set<string>();
    for await (const row of pageAll((o) => this.storage.delegations.list({ projectId, ...o }))) {
      ids.add(row.id);
    }
    for await (const row of pageAll((o) => this.storage.runsAudit.list({ projectId, ...o }))) {
      ids.add(row.id);
    }
    for await (const row of pageAll((o) => this.storage.escalations.list({ projectId, ...o }))) {
      ids.add(row.id);
    }
    return ids;
  }

  private async *eachProjectId(): AsyncGenerator<ProjectId> {
    for await (const project of pageAll((o) => this.storage.projects.list(o))) {
      yield project.id;
    }
  }
}

/** Drain a cursor-paginated repo `list` into an async iterator of rows. */
async function* pageAll<T>(
  list: (options: ListOptions) => Promise<ListResult<T>>,
): AsyncGenerator<T> {
  let cursor: string | undefined;
  do {
    const page: ListResult<T> = await list({ limit: 500, cursor });
    for (const item of page.items) yield item;
    cursor = page.nextCursor ?? undefined;
  } while (cursor !== undefined);
}
