// DelegationTreeService — assembles a run's live delegation tree.
//
// One physical `delegations` table; tree query is a single
// `WHERE root_delegation_id = ?` lookup followed by in-memory parent/child
// linkage. The root node is enriched with `runs_audit` data so the UI
// can show terminal state + result / error after the live row is gone.

import type { DelegationId } from "@katari-lang/runtime";
import { redactSecretsInEncrypted, valueToRaw } from "@katari-lang/runtime";
import type { RawValue } from "@katari-lang/types";
import type { DelegationRow, ProjectId, RunsAuditRow, Storage } from "../storage/types.js";

/**
 * Wire shape for one tree node. Owner is the Module currently running
 * this delegation; the UI labels nodes by owner endpoint.
 *
 * `state` mixes the live `delegations` table's `running | cancelling`
 * with the audit table's terminal states (`succeeded | cancelled |
 * error`) so the root node carries terminal info even after the live
 * row has been deleted.
 */
export type DelegationTreeNode = {
  delegationId: DelegationId;
  parentDelegationId: DelegationId | null;
  rootDelegationId: DelegationId;
  callerEndpoint: string;
  ownerEndpoint: string;
  agentDefId: string;
  qualifiedName: string | null;
  state: "running" | "cancelling" | "cancelled" | "error" | "succeeded";
  /** Present on the root node (= the run itself); always non-empty.
   *  Absent on non-root delegations. */
  name?: string;
  cancelReason?: "user" | "error" | null;
  args: Record<string, RawValue>;
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
  children: DelegationTreeNode[];
};

export type DelegationTree = {
  root: DelegationTreeNode;
  /** Timestamp the tree was assembled at (for polling staleness checks). */
  resolvedAt: string;
};

export class RunNotFound extends Error {
  constructor(public readonly runId: DelegationId) {
    super(`run ${runId} not found`);
  }
}

export class DelegationTreeService {
  constructor(private readonly storage: Storage) {}

  /**
   * Return the live tree rooted at `runId`. Throws `RunNotFound` if no
   * `runs_audit` row exists (= the run was never started, or the
   * snapshot was deleted out from under it).
   *
   * Authorization: when `projectId` is provided, asserts the audit row
   * belongs to that project; otherwise lets the caller verify.
   */
  async getTree(runId: DelegationId, projectId?: ProjectId): Promise<DelegationTree> {
    const audit = await this.storage.runsAudit.get(runId);
    if (audit === null) throw new RunNotFound(runId);
    if (projectId !== undefined) {
      const snapshot = await this.storage.snapshots.get(audit.snapshotId);
      if (snapshot === null || snapshot.projectId !== projectId) {
        throw new RunNotFound(runId);
      }
    }
    const { items: flat } = await this.storage.delegations.list({
      rootDelegationId: runId,
      limit: 500,
    });
    return {
      root: buildTree(runId, audit, flat),
      resolvedAt: new Date().toISOString(),
    };
  }
}

// ─── Internals ─────────────────────────────────────────────────────────────

function buildTree(
  rootId: DelegationId,
  audit: RunsAuditRow,
  flat: DelegationRow[],
): DelegationTreeNode {
  // Index by id and bucket by parent for O(N) tree build.
  const byId = new Map<DelegationId, DelegationRow>();
  const childrenOf = new Map<DelegationId | "__root__", DelegationRow[]>();
  for (const row of flat) {
    byId.set(row.id, row);
    const key: DelegationId | "__root__" = row.parentDelegationId ?? "__root__";
    const bucket = childrenOf.get(key);
    if (bucket === undefined) childrenOf.set(key, [row]);
    else bucket.push(row);
  }

  // Sort siblings by createdAt for deterministic UI rendering.
  for (const bucket of childrenOf.values()) {
    bucket.sort((a, b) => (a.createdAt < b.createdAt ? -1 : a.createdAt > b.createdAt ? 1 : 0));
  }

  // Root node draws state from audit (terminal-aware) and other fields
  // from the live row if it exists, else from audit (terminal case).
  const liveRoot = byId.get(rootId);
  return {
    delegationId: rootId,
    parentDelegationId: null,
    rootDelegationId: rootId,
    callerEndpoint: liveRoot?.callerEndpoint ?? "api://main",
    ownerEndpoint: liveRoot?.ownerEndpoint ?? "core://main",
    agentDefId: liveRoot?.agentDefId ?? `{qname:${audit.qualifiedName}}`,
    qualifiedName: audit.qualifiedName,
    state: audit.state,
    name: audit.name,
    cancelReason: audit.cancelReason,
    args: redactArgs(audit.args),
    result:
      audit.result === undefined ? undefined : valueToRaw(redactSecretsInEncrypted(audit.result)),
    errorMessage: audit.errorMessage,
    createdAt: audit.createdAt,
    updatedAt: audit.updatedAt,
    children: (childrenOf.get(rootId) ?? []).map((c) => buildLiveNode(c, childrenOf)),
  };
}

function buildLiveNode(
  row: DelegationRow,
  childrenOf: Map<DelegationId | "__root__", DelegationRow[]>,
): DelegationTreeNode {
  return {
    delegationId: row.id,
    parentDelegationId: row.parentDelegationId,
    rootDelegationId: row.rootDelegationId,
    callerEndpoint: row.callerEndpoint,
    ownerEndpoint: row.ownerEndpoint,
    agentDefId:
      typeof row.agentDefId === "string" ? row.agentDefId : JSON.stringify(row.agentDefId),
    qualifiedName: extractQualifiedName(row.agentDefId),
    state: row.state,
    args: redactArgs(row.args),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
    children: (childrenOf.get(row.id) ?? []).map((c) => buildLiveNode(c, childrenOf)),
  };
}

function redactArgs(
  args: Record<string, import("@katari-lang/runtime").EncryptedValue>,
): Record<string, RawValue> {
  const out: Record<string, RawValue> = {};
  for (const [k, v] of Object.entries(args)) {
    out[k] = valueToRaw(redactSecretsInEncrypted(v));
  }
  return out;
}

/**
 * Extract a human-readable qualified name from the wire-encoded
 * agentDefId, if it's a CORE qname. Returns null for opaque encodings
 * (= ext agent defs, prim agents).
 */
function extractQualifiedName(agentDefId: unknown): string | null {
  if (typeof agentDefId !== "string") return null;
  // CORE qname encoding (from `encodeCoreAgentDefId`): `{qname:foo.bar}`.
  // Anything else (`{ext:...}`, `{prim:...}`) maps to null and the UI
  // falls back to displaying the raw encoded form.
  const m = agentDefId.match(/^\{qname:(.+)\}$/);
  return m !== null ? m[1]! : null;
}
