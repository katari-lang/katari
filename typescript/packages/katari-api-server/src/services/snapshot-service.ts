// Snapshot CRUD service.
//
// `apply` 時の upload エンドポイントが直接呼び出す。`latest` 解決もここ。

import type {
  AgentDefinition,
  IRModule,
  Logger,
  SchemaBundle,
} from "katari-runtime";
import type {
  ListOptions,
  ProjectId,
  SidecarBundle,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
  Storage,
} from "../storage/types.js";

export class SnapshotNotFound extends Error {
  constructor(public readonly snapshotId: SnapshotId) {
    super(`snapshot ${snapshotId} does not exist`);
  }
}

export class AgentDefinitionNotFound extends Error {
  constructor(
    public readonly snapshotId: SnapshotId,
    public readonly qualifiedName: string,
  ) {
    super(
      `agent definition ${qualifiedName} does not exist in snapshot ${snapshotId}`,
    );
  }
}

/** 'QualifiedName' is already a flat dotted string; this helper exists for
 * call-site clarity (and is a no-op now). */
export function formatQualifiedName(qn: string): string {
  return qn;
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
  }): Promise<{ snapshotId: SnapshotId }> {
    const snapshotId = await this.storage.snapshots.insert(input);
    this.logger.log("info", "snapshot uploaded", {
      snapshotId,
      projectId: input.projectId,
      hasSidecar: input.sidecarBundle !== null,
    });
    return { snapshotId };
  }

  list(filter?: { projectId?: ProjectId } & ListOptions): Promise<SnapshotSummary[]> {
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
      throw new Error(
        `no snapshot exists for project ${input.projectId}`,
      );
    }
    return latest;
  }

  async listAgentDefinitions(snapshotId: SnapshotId): Promise<AgentDefinition[]> {
    const row = await this.get(snapshotId);
    return row.schemaBundle.agents;
  }

  async getAgentDefinition(
    snapshotId: SnapshotId,
    qualifiedName: string,
  ): Promise<AgentDefinition> {
    const defs = await this.listAgentDefinitions(snapshotId);
    const found = defs.find(
      (d) => formatQualifiedName(d.qualifiedName) === qualifiedName,
    );
    if (found === undefined) {
      throw new AgentDefinitionNotFound(snapshotId, qualifiedName);
    }
    return found;
  }

  async delete(snapshotId: SnapshotId): Promise<void> {
    const removed = await this.storage.snapshots.delete(snapshotId);
    if (!removed) throw new SnapshotNotFound(snapshotId);
    this.logger.log("info", "snapshot deleted", { snapshotId });
  }
}
