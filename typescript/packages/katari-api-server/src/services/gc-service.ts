// Blob GC crash backstop (Entity model).
//
// The primary GC is structural: a ref is owned by exactly one entity (FK
// CASCADE), and refcounts are maintained by the `refs` AFTER DELETE trigger, so
// a completed entity's non-escaping refs are dropped + their blobs freed
// automatically. Escaping refs ascend value-driven (detach → claim). There is no
// "dead owner" state to reconcile — the FK forbids a ref pointing at a missing
// entity.
//
// The only crash residue is an IN-TRANSIT ref: one a terminating child detached
// (`owner_entity_id = NULL`) but whose parent's claim was lost to a crash. This
// backstop drops those + reaps any blob whose refcount hit 0.
//
// SAFETY: a while-live ref is `NULL`-owned for sub-seconds mid-ascent, so the
// detached-ref sweep MUST run only when nothing is concurrently ascending —
// i.e. at BOOT, before the server accepts traffic.

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
        // Drop crash-orphaned in-transit refs, then reap any blobs that fell to
        // refcount 0 (here + via prior entity-cascade deletes).
        const freed = await this.storage.values.sweepDetachedRefs(projectId);
        const reaped = await this.storage.values.reapFreedBlobs(projectId);
        if (freed > 0 || reaped > 0) {
          this.logger.log("info", "gc: reclaimed orphaned blobs on boot", {
            projectId,
            freed: freed + reaped,
          });
        }
      } catch (err) {
        this.logger.log("warn", "gc: project sweep failed", {
          projectId,
          err: err instanceof Error ? err.message : String(err),
        });
      }
    }
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
