// EntityTreeService — assembles a run's execution tree for the operator UI.
//
// The tree is the entity forest under a run. Entities carry no parent link (it
// is off-server, see docs/2026-06-01-entity-model.md); the edges live on the
// issuer-side `delegations` rows (`parent_entity_id`). So the tree is built by a
// local BFS: from the run-root entity, follow the delegations it (and its
// descendants) issued, resolving each to the receiver's entity. This is an
// aggregator-side, single-server walk — not a hot path, and not a cross-module
// read on the protocol path (the API assembles the operator view).
//
// The root node is enriched with the Run record (terminal state + result),
// which carries the `done` / `error` outcome no entity state holds.

import { type EncryptedValue, redactSecretsInEncrypted, valueToRaw } from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/types";
import type {
  CancelReason,
  EntityModule,
  ProjectId,
  RunId,
  RunRow,
  RunState,
  Storage,
} from "../storage/types.js";

export type RunTreeNode = {
  entityId: string;
  delegationId: string | null;
  parentEntityId: string | null;
  module: EntityModule;
  agentDefId: string | null;
  qualifiedName: string | null;
  /** Entity state for inner nodes; the Run's state for the root. */
  state: RunState;
  /** Present on the root node (= the run). */
  name?: string;
  cancelReason?: CancelReason | null;
  args: Record<string, RawValue>;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  children: RunTreeNode[];
};

export type RunTree = {
  root: RunTreeNode;
  /** Timestamp the tree was assembled at (for polling staleness checks). */
  resolvedAt: string;
};

export class RunNotFound extends Error {
  constructor(public readonly runId: RunId) {
    super(`run ${runId} not found`);
  }
}

const MAX_NODES = 2000;

export class EntityTreeService {
  constructor(private readonly storage: Storage) {}

  /**
   * Return the execution tree rooted at `runId`. Throws `RunNotFound` if no Run
   * record exists. When `projectId` is provided, asserts the run belongs to it.
   */
  async getTree(runId: RunId, projectId?: ProjectId): Promise<RunTree> {
    const run = await this.storage.runs.get(runId);
    if (run === null) throw new RunNotFound(runId);
    if (projectId !== undefined && run.projectId !== projectId) throw new RunNotFound(runId);

    const budget = { left: MAX_NODES };
    const root = await this.buildNode(run.projectId, runId, null, null, run, budget);
    return { root, resolvedAt: new Date().toISOString() };
  }

  /** Build the node for `entityId` and recurse into the delegations it issued. */
  private async buildNode(
    projectId: ProjectId,
    entityId: string,
    delegationId: string | null,
    parentEntityId: string | null,
    run: RunRow | null,
    budget: { left: number },
  ): Promise<RunTreeNode> {
    const entity = await this.storage.entities.get(entityId as never);
    const children: RunTreeNode[] = [];
    if (budget.left > 0) {
      const dels = await this.storage.delegations.list({
        projectId,
        parentEntityId: entityId as never,
        limit: 500,
      });
      for (const del of dels.items) {
        if (budget.left <= 0) break;
        budget.left -= 1;
        const child = await this.storage.entities.getByDelegation(projectId, del.id);
        if (child !== null) {
          children.push(await this.buildNode(projectId, child.id, del.id, entityId, null, budget));
        }
      }
    }

    const agentDefId = run !== null ? null : entityAgentDefId(entity?.agentDefId);
    const args = run !== null ? redactArgs(run.args) : redactArgs(entity?.args ?? {});
    return {
      entityId,
      delegationId,
      parentEntityId,
      module: entity?.module ?? "api",
      agentDefId,
      qualifiedName:
        run !== null ? run.qualifiedName : extractQualifiedName(entity?.agentDefId ?? null),
      state: run !== null ? run.state : (entity?.state ?? "running"),
      name: run !== null ? run.name : undefined,
      cancelReason: run !== null ? run.cancelReason : undefined,
      args,
      result:
        run !== null && run.result !== undefined
          ? valueToRaw(redactSecretsInEncrypted(run.result))
          : undefined,
      errorMessage: run !== null ? run.errorMessage : undefined,
      createdAt: entity?.createdAt ?? run?.createdAt ?? "",
      updatedAt: entity?.updatedAt ?? run?.updatedAt ?? "",
      children,
    };
  }
}

function entityAgentDefId(agentDefId: unknown): string | null {
  if (agentDefId === null || agentDefId === undefined) return null;
  return typeof agentDefId === "string" ? agentDefId : JSON.stringify(agentDefId);
}

function redactArgs(args: Record<string, EncryptedValue>): Record<string, RawValue> {
  const out: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return out;
}

/** Extract a human-readable qualified name from a CORE qname agentDefId. */
function extractQualifiedName(agentDefId: unknown): string | null {
  if (typeof agentDefId !== "string") return null;
  const m = agentDefId.match(/^\{qname:(.+)\}$/);
  return m !== null ? m[1]! : null;
}
