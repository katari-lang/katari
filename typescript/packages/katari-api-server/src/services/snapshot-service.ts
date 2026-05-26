// Snapshot CRUD service.
//
// Called directly by the upload endpoint at `apply` time. `latest` resolution is also here.

import {
  SnapshotNotFound,
  NoSnapshotForProject,
  type AgentDefinition,
  type IRModule,
  type Logger,
  type SchemaBundle,
} from "@katari-lang/runtime";
import type {
  ListOptions,
  ListResult,
  ProjectId,
  SidecarBundle,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
  Storage,
} from "../storage/types.js";

// Re-export so existing callers keep working.
export { SnapshotNotFound, NoSnapshotForProject };

export class AgentNotFound extends Error {
  constructor(
    public readonly snapshotId: SnapshotId,
    public readonly qualifiedName: string,
  ) {
    super(
      `agent ${qualifiedName} does not exist in snapshot ${snapshotId}`,
    );
  }
}

/** 'QualifiedName' is already a flat dotted string; this helper exists for
 * call-site clarity (and is a no-op now). */
export function formatQualifiedName(qn: string): string {
  return qn;
}

/** Default snapshot message used when the operator omits `-m`. Format
 *  mirrors the snapshot list's primary display so a click-through reads
 *  cleanly. */
export function defaultSnapshotMessage(now: Date): string {
  const y = now.getFullYear();
  const mo = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  const h = String(now.getHours()).padStart(2, "0");
  const mi = String(now.getMinutes()).padStart(2, "0");
  return `snapshot @ ${y}-${mo}-${d} ${h}:${mi}`;
}

export class SnapshotService {
  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
  ) {}

  async upload(input: {
    projectId: ProjectId;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
    /** Operator-supplied commit-message-like text. When `null` / omitted,
     *  the service substitutes a default like `"snapshot @ 2026-05-25 15:42"`
     *  so downstream rows always carry a human-readable label. */
    message?: string | null;
  }): Promise<{ snapshotId: SnapshotId }> {
    const message =
      input.message !== null && input.message !== undefined && input.message !== ""
        ? input.message
        : defaultSnapshotMessage(new Date());
    const snapshotId = await this.storage.snapshots.insert({
      ...input,
      message,
    });
    this.logger.log("info", "snapshot uploaded", {
      snapshotId,
      projectId: input.projectId,
      hasSidecar: input.sidecarBundle !== null,
    });
    return { snapshotId };
  }

  list(filter?: { projectId?: ProjectId } & ListOptions): Promise<ListResult<SnapshotSummary>> {
    return this.storage.snapshots.list(filter);
  }

  async get(snapshotId: SnapshotId): Promise<Snapshot> {
    const row = await this.storage.snapshots.get(snapshotId);
    if (row === null) throw new SnapshotNotFound(snapshotId);
    return row;
  }

  /**
   * Resolve `(projectId, snapshotId?)` to a concrete SnapshotId. If
   * snapshotId is provided it's returned as-is; otherwise the latest
   * snapshot for the project is used.
   */
  async resolve(input: {
    projectId: ProjectId;
    snapshotId?: SnapshotId;
  }): Promise<SnapshotId> {
    if (input.snapshotId !== undefined) return input.snapshotId;
    const latest = await this.storage.snapshots.latest(input.projectId);
    if (latest === null) {
      throw new NoSnapshotForProject(input.projectId);
    }
    return latest;
  }

  async listAgents(snapshotId: SnapshotId): Promise<AgentDefinition[]> {
    const row = await this.get(snapshotId);
    return row.schemaBundle.agents;
  }

  async getAgent(
    snapshotId: SnapshotId,
    qualifiedName: string,
  ): Promise<AgentDefinition> {
    const agents = await this.listAgents(snapshotId);
    const found = agents.find(
      (a) => formatQualifiedName(a.qualifiedName) === qualifiedName,
    );
    if (found === undefined) {
      throw new AgentNotFound(snapshotId, qualifiedName);
    }
    return found;
  }

  async delete(snapshotId: SnapshotId): Promise<void> {
    const removed = await this.storage.snapshots.delete(snapshotId);
    if (!removed) throw new SnapshotNotFound(snapshotId);
    this.logger.log("info", "snapshot deleted", { snapshotId });
  }
}
