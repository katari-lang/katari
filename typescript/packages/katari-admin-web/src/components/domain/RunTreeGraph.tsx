import {
  Background,
  Controls,
  type Edge,
  Handle,
  type Node,
  type NodeProps,
  Position,
  ReactFlow,
} from "@xyflow/react";
import dagre from "dagre";
import { useCallback, useMemo } from "react";
import "@xyflow/react/dist/style.css";
import type { RunTreeNode } from "@/api/types";
import { cn } from "@/lib/cn";
import { RunStatusBadge } from "./RunStatusBadge";

const NODE_WIDTH = 280;
const NODE_HEIGHT = 80;

type RunTreeNodeData = {
  treeNode: RunTreeNode;
};

function RunTreeNodeCard({ data }: NodeProps<Node<RunTreeNodeData>>) {
  const node = data.treeNode;
  const ownerLabel = node.module.toUpperCase();
  return (
    <>
      <Handle type="target" position={Position.Top} className="!bg-border !border-0 !w-2 !h-1" />
      <div
        className={cn(
          "w-[280px] border bg-background px-3 py-2 text-left",
          node.state === "running" && "border-info/40",
          node.state === "cancelling" && "border-warning/40",
          node.state === "error" && "border-danger/40",
          node.state === "done" && "border-success/40",
          !["running", "cancelling", "error", "done"].includes(node.state) && "border-border",
        )}
      >
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs uppercase tracking-wider text-subtle-foreground">
            {ownerLabel}
          </span>
          <RunStatusBadge state={node.state} cancelReason={node.cancelReason} />
        </div>
        <div className="mt-1 truncate font-mono text-xs text-foreground">
          {node.qualifiedName ?? node.agentDefId}
        </div>
        {node.name !== undefined && (
          <div className="mt-0.5 truncate text-xs text-subtle-foreground">{node.name}</div>
        )}
      </div>
      <Handle type="source" position={Position.Bottom} className="!bg-border !border-0 !w-2 !h-1" />
    </>
  );
}

const nodeTypes = { run: RunTreeNodeCard };

function flattenTree(
  node: RunTreeNode,
  parentId: string | null,
  nodes: Node<RunTreeNodeData>[],
  edges: Edge[],
): void {
  const id = node.entityId;
  nodes.push({
    id,
    type: "run",
    position: { x: 0, y: 0 },
    data: { treeNode: node },
  });
  if (parentId !== null) {
    edges.push({
      id: `${parentId}-${id}`,
      source: parentId,
      target: id,
      type: "smoothstep",
      style: { stroke: "var(--color-border)", strokeWidth: 1 },
    });
  }
  for (const child of node.children) {
    flattenTree(child, id, nodes, edges);
  }
}

function layoutWithDagre(nodes: Node[], edges: Edge[]): void {
  const g = new dagre.graphlib.Graph();
  g.setGraph({ rankdir: "TB", nodesep: 40, ranksep: 60 });
  g.setDefaultEdgeLabel(() => ({}));

  for (const node of nodes) {
    g.setNode(node.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
  }
  for (const edge of edges) {
    g.setEdge(edge.source, edge.target);
  }

  dagre.layout(g);

  for (const node of nodes) {
    const pos = g.node(node.id);
    node.position = { x: pos.x - NODE_WIDTH / 2, y: pos.y - NODE_HEIGHT / 2 };
  }
}

export function RunTreeGraph({ root }: { root: RunTreeNode }) {
  const { nodes, edges } = useMemo(() => {
    const nodes: Node<RunTreeNodeData>[] = [];
    const edges: Edge[] = [];
    flattenTree(root, null, nodes, edges);
    layoutWithDagre(nodes, edges);
    return { nodes, edges };
  }, [root]);

  const proOptions = useMemo(() => ({ hideAttribution: true }), []);
  const fitViewOptions = useMemo(() => ({ padding: 0.2 }), []);
  const defaultViewport = useMemo(() => ({ x: 0, y: 0, zoom: 1 }), []);
  const onInit = useCallback((instance: { fitView: () => void }) => {
    instance.fitView();
  }, []);

  return (
    <div className="h-[600px] border border-border bg-muted/20">
      <ReactFlow
        nodes={nodes}
        edges={edges}
        nodeTypes={nodeTypes}
        proOptions={proOptions}
        fitView
        fitViewOptions={fitViewOptions}
        defaultViewport={defaultViewport}
        onInit={onInit}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        minZoom={0.1}
        maxZoom={2}
      >
        <Background gap={16} size={1} />
        <Controls
          showInteractive={false}
          className="!border-border !bg-background !shadow-none [&>button]:!border-border [&>button]:!bg-background [&>button]:!rounded-none"
        />
      </ReactFlow>
    </div>
  );
}
