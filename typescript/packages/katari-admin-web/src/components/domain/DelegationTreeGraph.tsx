import { motion } from "framer-motion";
import { ArrowDown } from "lucide-react";
import { cn } from "@/lib/cn";
import { RunStatusBadge } from "./RunStatusBadge";
import type { DelegationTreeNode } from "@/api/types";

/**
 * Render a delegation tree as a vertical layout: root at top, children
 * fanned out below, each branch recursively a sub-tree. Edges are simple
 * downward arrows — no React Flow / dagre for v0.1.0 (= keep the bundle
 * size and code surface small).
 */
export function DelegationTreeGraph({ root }: { root: DelegationTreeNode }) {
  return (
    <div className="flex flex-col items-center gap-2 py-4">
      <TreeNode node={root} depth={0} />
    </div>
  );
}

function TreeNode({
  node,
  depth,
}: {
  node: DelegationTreeNode;
  depth: number;
}) {
  return (
    <motion.div
      initial={{ opacity: 0, y: -4 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ duration: 0.15, delay: depth * 0.04 }}
      className="flex flex-col items-center"
    >
      <NodeCard node={node} />
      {node.children.length > 0 && (
        <>
          <ArrowDown className="my-1 size-4 text-subtle-foreground" />
          <div className="flex flex-row flex-wrap items-start justify-center gap-6">
            {node.children.map((child) => (
              <TreeNode
                key={child.delegationId}
                node={child}
                depth={depth + 1}
              />
            ))}
          </div>
        </>
      )}
    </motion.div>
  );
}

function NodeCard({ node }: { node: DelegationTreeNode }) {
  // Compact endpoint label: `core://main` → `CORE`. Short and recognisable.
  const ownerLabel = shortEndpoint(node.ownerEndpoint);
  return (
    <div
      className={cn(
        "min-w-[180px] border border-border bg-background px-3 py-2 text-left",
        node.state === "running" && "border-info/40",
        node.state === "cancelling" && "border-warning/40",
        node.state === "error" && "border-danger/40",
      )}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="text-[10px] uppercase tracking-wider text-subtle-foreground">
          {ownerLabel}
        </span>
        <RunStatusBadge state={node.state} />
      </div>
      <div className="mt-1 font-mono text-xs text-foreground">
        {node.qualifiedName ?? node.agentDefId}
      </div>
      {node.name !== undefined && node.name !== null && (
        <div className="mt-0.5 text-[11px] text-subtle-foreground">
          {node.name}
        </div>
      )}
    </div>
  );
}

function shortEndpoint(endpoint: string): string {
  // Strip a scheme prefix like `core://` and uppercase the rest. `ext://ffi`
  // → `FFI`, `core://main` → `CORE`, custom endpoints fall through unchanged.
  const stripped = endpoint.replace(/^(core|api|ext):\/\//, "");
  if (endpoint.startsWith("core://")) return "CORE";
  if (endpoint.startsWith("api://")) return "API";
  if (endpoint.startsWith("ext://")) return stripped.toUpperCase();
  return endpoint;
}
