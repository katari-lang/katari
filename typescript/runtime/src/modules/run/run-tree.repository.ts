// The delegation tree of one run — who summoned whom, right now. This reads the Layer 1 `delegations` +
// `instances` (and their kind extensions) directly, the same durable rows every reactor's warm
// `issuedByCaller` / `handled` indexes are rebuilt from on recovery, so the API and the engine always agree
// and no reactor has to be loaded (or kept loaded) just to look at a run. The rows are pure live routing —
// a finished delegation is deleted — so the tree is inherently a *live* view: a terminal run has none.
//
// The edges compose exactly as the base reactor documents them: a delegation's callee is the instance whose
// `delegation_id` correlates it, and an instance's children are the delegations whose `caller_instance_id`
// is that instance — `issuedDelegationsOf(handledInstanceOf(parent))`, read from the durable mirror. All
// rows are fetched project-scoped in one pass (live rows are bounded by running work) and assembled in
// memory, so the walk needs no recursive SQL and a corrupt cycle cannot hang it.

import { eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import {
  coreInstances,
  type DelegationState,
  delegations,
  escalations,
  externalCallInstances,
  instances,
} from "../../db/tables/execution.js";
import { decodeFfiExtension } from "../../runtime/actor/ffi-reactor.js";
import type { InstanceKind } from "../../runtime/engine/types.js";
import { isUserFacingRequest } from "../../runtime/escalation-filter.js";
import type { DelegateTarget, ReactorName } from "../../runtime/event/types.js";

/** What a tree node's instance runs, projected for display: a named agent, a closure, or an external
 *  handler's dispatch key. `null` when the kind stores no target (an http call keeps no request). */
export type TreeTarget =
  | { kind: "agent"; name: string }
  | { kind: "closure"; blockId: number; module: string }
  | { kind: "external"; key: string };

/** An open question a node's instance has raised. `answerable` marks the leg addressed to the api root —
 *  the one the answer surface accepts; a relay leg (core / ffi hop of the same bubbling question) is not. */
export interface TreeEscalation {
  id: string;
  request: string;
  answerable: boolean;
  createdAt: Date;
}

/** The callee side of a delegation: the instance handling it, its children, and its open questions.
 *  `status` prefers the kind extension's view (an ffi / http call distinguishes `awaitingAnswer`). */
export interface TreeInstance {
  id: string;
  kind: InstanceKind;
  status: "running" | "cancelling" | "awaitingAnswer";
  target: TreeTarget | null;
  snapshotId: string | null;
  openEscalations: TreeEscalation[];
  children: DelegationTreeNode[];
}

/** One live delegation edge. `reactor` is the callee's reactor (the edge's `to`); `instance` is `null`
 *  while the `delegate` is still in the outbox (issued but not yet accepted by the callee). */
export interface DelegationTreeNode {
  delegationId: string;
  state: DelegationState;
  reactor: ReactorName;
  createdAt: Date;
  instance: TreeInstance | null;
}

/** The project-scoped row shapes the assembly consumes (what the queries below select). */
export interface TreeDelegationRow {
  id: string;
  callerInstanceId: string | null;
  toReactor: ReactorName;
  state: DelegationState;
  createdAt: Date;
}

export interface TreeInstanceRow {
  id: string;
  delegationId: string | null;
  kind: InstanceKind;
  status: "running" | "cancelling";
  /** The `core` extension's target — what the instance runs. */
  target: DelegateTarget | null;
  /** The `ffi` extension's dispatch key. */
  ffiKey: string | null;
  /** An external call's own status (it distinguishes `awaitingAnswer`; the envelope cannot). */
  callStatus: "running" | "cancelling" | "awaitingAnswer" | null;
  snapshotId: string | null;
}

export interface TreeEscalationRow {
  id: string;
  raiserInstanceId: string;
  request: string;
  toReactor: ReactorName;
  createdAt: Date;
}

/** Assemble the tree rooted at `runId` — the run's permanent api-side instance, whose single issued
 *  delegation is the tree's root edge. Pure — the testable heart of the read path. Returns `null` when that
 *  delegation is gone (the run is terminal, or never started). A visited guard makes corrupt rows degrade
 *  to a truncated tree, never a hang. */
export function assembleDelegationTree(
  runId: string,
  rows: {
    delegations: TreeDelegationRow[];
    instances: TreeInstanceRow[];
    escalations: TreeEscalationRow[];
  },
): DelegationTreeNode | null {
  const calleeByDelegation = new Map<string, TreeInstanceRow>();
  for (const instance of rows.instances) {
    if (instance.delegationId !== null) calleeByDelegation.set(instance.delegationId, instance);
  }
  const childrenByCaller = new Map<string, TreeDelegationRow[]>();
  for (const delegation of rows.delegations) {
    if (delegation.callerInstanceId === null) continue;
    const siblings = childrenByCaller.get(delegation.callerInstanceId);
    if (siblings === undefined) childrenByCaller.set(delegation.callerInstanceId, [delegation]);
    else siblings.push(delegation);
  }
  const escalationsByRaiser = new Map<string, TreeEscalationRow[]>();
  for (const escalation of rows.escalations) {
    const raised = escalationsByRaiser.get(escalation.raiserInstanceId);
    if (raised === undefined) escalationsByRaiser.set(escalation.raiserInstanceId, [escalation]);
    else raised.push(escalation);
  }

  // The run instance is the caller of exactly one delegation — the run's live root edge.
  const root = rows.delegations.find((delegation) => delegation.callerInstanceId === runId);
  if (root === undefined) return null;

  const visited = new Set<string>();
  const nodeOf = (delegation: TreeDelegationRow): DelegationTreeNode => {
    visited.add(delegation.id);
    const callee = calleeByDelegation.get(delegation.id);
    return {
      delegationId: delegation.id,
      state: delegation.state,
      reactor: delegation.toReactor,
      createdAt: delegation.createdAt,
      instance: callee === undefined || visited.has(callee.id) ? null : instanceOf(callee),
    };
  };
  const instanceOf = (instance: TreeInstanceRow): TreeInstance => {
    visited.add(instance.id);
    const children = (childrenByCaller.get(instance.id) ?? [])
      .filter((child) => !visited.has(child.id))
      .sort(byAge);
    return {
      id: instance.id,
      kind: instance.kind,
      status: instance.callStatus ?? instance.status,
      target: targetOf(instance),
      snapshotId: instance.snapshotId,
      openEscalations: (escalationsByRaiser.get(instance.id) ?? [])
        .map((escalation) => ({
          id: escalation.id,
          request: escalation.request,
          // Answerable = addressed to the api root AND a genuine user-facing request. A run-root failure
          // (panic / throw / control escape) is a `to = api` row too now (the base opens every escalate a
          // row), so the user-facing check — not `to === 'api'` alone — is what marks it un-answerable.
          answerable: escalation.toReactor === "api" && isUserFacingRequest(escalation.request),
          createdAt: escalation.createdAt,
        }))
        .sort(byAge),
      children: children.map(nodeOf),
    };
  };
  return nodeOf(root);
}

function byAge(left: { createdAt: Date }, right: { createdAt: Date }): number {
  return left.createdAt.getTime() - right.createdAt.getTime();
}

/** Project an instance row's kind extension to its display target. */
function targetOf(instance: TreeInstanceRow): TreeTarget | null {
  if (instance.target !== null) {
    switch (instance.target.kind) {
      case "named":
        return { kind: "agent", name: instance.target.name };
      case "closure":
        return {
          kind: "closure",
          blockId: instance.target.blockId,
          module: instance.target.module,
        };
      case "external":
        return { kind: "external", key: instance.target.key };
    }
  }
  if (instance.ffiKey !== null) return { kind: "external", key: instance.ffiKey };
  return null;
}

export const runTreeRepository = {
  /** The live delegation tree of one run, or `null` when it has none (terminal / not yet started). */
  async get(
    executor: Executor,
    projectId: string,
    runId: string,
  ): Promise<DelegationTreeNode | null> {
    const [delegationRows, instanceRows, escalationRows] = await Promise.all([
      executor
        .select({
          id: delegations.id,
          callerInstanceId: delegations.callerInstanceId,
          toReactor: delegations.toReactor,
          state: delegations.state,
          createdAt: delegations.createdAt,
        })
        .from(delegations)
        .where(eq(delegations.projectId, projectId)),
      executor
        .select({
          id: instances.id,
          delegationId: instances.delegationId,
          kind: instances.kind,
          status: instances.status,
          target: coreInstances.target,
          coreSnapshotId: coreInstances.snapshotId,
          callStatus: externalCallInstances.status,
          extension: externalCallInstances.extension,
        })
        .from(instances)
        .leftJoin(coreInstances, eq(coreInstances.instanceId, instances.id))
        .leftJoin(externalCallInstances, eq(externalCallInstances.instanceId, instances.id))
        .where(eq(instances.projectId, projectId)),
      executor
        .select({
          id: escalations.id,
          raiserInstanceId: escalations.raiserInstanceId,
          request: escalations.request,
          toReactor: escalations.toReactor,
          createdAt: escalations.createdAt,
        })
        .from(escalations)
        .where(eq(escalations.projectId, projectId)),
    ]);
    return assembleDelegationTree(runId, {
      delegations: delegationRows,
      instances: instanceRows.map((row) => {
        // The ffi display fields (dispatch key, snapshot pin) live inside the extension document, so they
        // decode through the reactor's exported pure codec — never SQL `->>` digging, which would
        // silently duplicate the schema the codec owns. The volume is one run's live rows, and the
        // decoded fields are not private (any `$katari_sealed` node elsewhere in a document stays untouched).
        const ffi =
          row.kind === "ffi" && row.extension !== null ? decodeFfiExtension(row.extension) : null;
        return {
          id: row.id,
          delegationId: row.delegationId,
          kind: row.kind,
          status: row.status,
          target: row.target,
          ffiKey: ffi === null ? null : ffi.key,
          callStatus: row.callStatus,
          snapshotId: row.coreSnapshotId ?? (ffi === null ? null : ffi.snapshotId),
        };
      }),
      escalations: escalationRows,
    });
  },
};
