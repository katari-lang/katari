// Module CRUD. Thin wrapper over `ModuleRepo` that adds AI tool-calling
// "agent definition" projection (one entry per qualifiedName in the
// associated SchemaBundle).

import type {
  AgentDefinition,
  IRModule,
  Logger,
  SchemaBundle,
} from "katari-runtime";
import type {
  ModuleRow,
  ModuleSummary,
  Storage,
  VersionId,
} from "../storage/types.js";

export class ModuleNotFound extends Error {
  constructor(public readonly versionId: VersionId) {
    super(`module version ${versionId} does not exist`);
  }
}

export class AgentDefinitionNotFound extends Error {
  constructor(
    public readonly versionId: VersionId,
    public readonly qualifiedName: string,
  ) {
    super(
      `agent definition ${qualifiedName} does not exist in version ${versionId}`,
    );
  }
}

/**
 * Canonical string form of a `QualifiedName`. `module_` may be empty for
 * top-level / root entries — in that case the bare `name` is the canonical
 * form (matches the convention used in IRModule.entries keys for unmoduled
 * agents in the existing test fixtures).
 */
export function formatQualifiedName(qn: {
  module_: string;
  name: string;
}): string {
  return qn.module_ === "" ? qn.name : `${qn.module_}.${qn.name}`;
}

export class ModuleService {
  constructor(
    private readonly storage: Storage,
    private readonly logger: Logger,
  ) {}

  async upload(input: {
    irModule: IRModule;
    schemaBundle: SchemaBundle;
  }): Promise<{ versionId: VersionId }> {
    const name = input.irModule.name ?? "(unnamed)";
    const versionId = await this.storage.modules.insert({
      irModule: input.irModule,
      schemaBundle: input.schemaBundle,
      name,
    });
    this.logger.log("info", "module uploaded", { versionId, name });
    return { versionId };
  }

  list(options?: { limit?: number; offset?: number }): Promise<ModuleSummary[]> {
    return this.storage.modules.list(options);
  }

  async get(versionId: VersionId): Promise<ModuleRow> {
    const row = await this.storage.modules.get(versionId);
    if (row === null) throw new ModuleNotFound(versionId);
    return row;
  }

  async listAgentDefinitions(
    versionId: VersionId,
  ): Promise<AgentDefinition[]> {
    const row = await this.get(versionId);
    return row.schemaBundle.agents;
  }

  async getAgentDefinition(
    versionId: VersionId,
    qualifiedName: string,
  ): Promise<AgentDefinition> {
    const defs = await this.listAgentDefinitions(versionId);
    const found = defs.find(
      (d) => formatQualifiedName(d.qualifiedName) === qualifiedName,
    );
    if (found === undefined) {
      throw new AgentDefinitionNotFound(versionId, qualifiedName);
    }
    return found;
  }

  /**
   * Delete a module version. Throws `ModuleNotFound` if the version
   * doesn't exist. The storage layer's FK from `agents.version_id`
   * ensures we cannot delete a version that still has agents.
   */
  async delete(versionId: VersionId): Promise<void> {
    const removed = await this.storage.modules.delete(versionId);
    if (!removed) throw new ModuleNotFound(versionId);
    this.logger.log("info", "module deleted", { versionId });
  }
}
