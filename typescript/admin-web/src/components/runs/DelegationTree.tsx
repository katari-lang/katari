// The live delegation tree of a run: who summoned whom, right now. Each node is one delegation edge
// with the instance handling it — its agent / handler label, its status, and any open question it has
// raised (the badged path leads to where the run is actually waiting). The rows are live routing on the
// runtime side, so a finished run renders as "no live delegations" rather than a historical trace.

import { Bot, CircleHelp, Clock, FunctionSquare, Globe, Plug } from "lucide-react";
import type { DelegationTreeNode, TreeInstance, TreeTarget } from "../../api/types";
import { Badge } from "../ui/Badge";

export function DelegationTree({ root }: { root: DelegationTreeNode }) {
  return (
    <div className="overflow-x-auto font-mono text-xs leading-relaxed">
      <TreeNode node={root} />
    </div>
  );
}

function TreeNode({ node }: { node: DelegationTreeNode }) {
  return (
    <div className="flex flex-col">
      <div className="flex flex-wrap items-center gap-2 py-0.5">
        <KindIcon instance={node.instance} reactor={node.reactor} />
        <span className="text-fg">{labelOf(node)}</span>
        <StatusBadge node={node} />
        {node.instance?.openEscalations.map((escalation) => (
          <Badge key={escalation.id} tone={escalation.answerable ? "warning" : "neutral"}>
            <CircleHelp className="size-3" />
            {escalation.request}
            {!escalation.answerable && " (relay)"}
          </Badge>
        ))}
      </div>
      {(node.instance?.children.length ?? 0) > 0 && (
        <div className="flex flex-col border-l border-edge pl-5">
          {node.instance?.children.map((child) => (
            <TreeNode key={child.delegationId} node={child} />
          ))}
        </div>
      )}
    </div>
  );
}

function KindIcon({
  instance,
  reactor,
}: {
  instance: TreeInstance | null;
  reactor: DelegationTreeNode["reactor"];
}) {
  const kind = instance?.kind ?? reactor;
  const className = "size-3.5 shrink-0 text-fg-faint";
  switch (kind) {
    case "ffi":
      return <Plug className={className} />;
    case "http":
      return <Globe className={className} />;
    case "core":
      return instance?.target?.kind === "closure" ? (
        <FunctionSquare className={className} />
      ) : (
        <Bot className={className} />
      );
    default:
      return <Bot className={className} />;
  }
}

/** The node's display name: its target when the instance landed, else "in flight" for a delegate the
 *  callee has not accepted yet. */
function labelOf(node: DelegationTreeNode): string {
  if (node.instance === null) return `${node.reactor} · in flight`;
  return node.instance.target === null ? node.instance.kind : targetLabel(node.instance.target);
}

function targetLabel(target: TreeTarget): string {
  switch (target.kind) {
    case "agent":
      return target.name;
    case "closure":
      return `closure ${target.module}#${target.blockId}`;
    case "external":
      return target.key;
  }
}

function StatusBadge({ node }: { node: DelegationTreeNode }) {
  if (node.instance === null) {
    return (
      <Badge tone="neutral">
        <Clock className="size-3" /> pending
      </Badge>
    );
  }
  // `cancelling` on either the edge or the instance wins over a plain `running`.
  if (node.state === "cancelling" || node.instance.status === "cancelling") {
    return <Badge tone="warning">cancelling</Badge>;
  }
  if (node.instance.status === "awaitingAnswer") {
    return <Badge tone="warning">awaiting answer</Badge>;
  }
  return <Badge tone="info">running</Badge>;
}
