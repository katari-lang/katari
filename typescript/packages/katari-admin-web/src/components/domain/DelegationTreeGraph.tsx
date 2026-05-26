import { useMemo, useCallback } from "react";
import {
  ReactFlow,
  Background,
  Controls,
  MiniMap,
  type Node,
  type Edge,
  type NodeProps,
  Handle,
  Position,
} from "@xyflow/react";
import dagre from "dagre";
import "@xyflow/react/dist/style.css";
import { cn } from "@/lib/cn";
import { RunStatusBadge } from "./RunStatusBadge";
import type { DelegationTreeNode } from "@/api/types";

const NODE_WIDTH = 280;
const NODE_HEIGHT = 80;

type DelegationNodeData = {
  treeNode: DelegationTreeNode;
};

function DelegationNode({ data }: NodeProps<Node<DelegationNodeData>>) {
  const node = data.treeNode;
  const ownerLabel = shortEndpoint(node.ownerEndpoint);
  return (
    <>
      <Handle type="target" position={Position.Top} className="!bg-border !border-0 !w-2 !h-1" />
      <div
        className={cn(
          "w-[280px] border bg-background px-3 py-2 text-left",
          node.state === "running" && "border-info/40",
          node.state === "cancelling" && "border-warning/40",
          node.state === "error" && "border-danger/40",
          node.state === "succeeded" && "border-success/40",
          node.state === "cancelled" && "border-border",
          !["running", "cancelling", "error", "succeeded"].includes(node.state) && "border-border",
        )}
      >
        <div className="flex items-center justify-between gap-2">
          <span className="text-xs uppercase tracking-wider text-subtle-foreground">
            {ownerLabel}
          </span>
          <RunStatusBadge state={node.state} />
        </div>
        <div className="mt-1 truncate font-mono text-xs text-foreground">
          {node.qualifiedName ?? node.agentDefId}
        </div>
        {node.name !== undefined && (
          <div className="mt-0.5 truncate text-xs text-subtle-foreground">
            {node.name}
          </div>
        )}
      </div>
      <Handle type="source" position={Position.Bottom} className="!bg-border !border-0 !w-2 !h-1" />
    </>
  );
}

const nodeTypes = { delegation: DelegationNode };

function flattenTree(
  node: DelegationTreeNode,
  parentId: string | null,
  nodes: Node<DelegationNodeData>[],
  edges: Edge[],
): void {
  const id = node.delegationId;
  nodes.push({
    id,
    type: "delegation",
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

export function DelegationTreeGraph({ root }: { root: DelegationTreeNode }) {
  const { nodes, edges } = useMemo(() => {
    const nodes: Node<DelegationNodeData>[] = [];
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
        <MiniMap
          nodeColor="var(--color-border)"
          maskColor="var(--color-background)"
          className="!border-border !bg-background !rounded-none !shadow-none"
        />
      </ReactFlow>
    </div>
  );
}

function shortEndpoint(endpoint: string): string {
  const stripped = endpoint.replace(/^(core|api|ext):\/\//, "");
  if (endpoint.startsWith("core://")) return "CORE";
  if (endpoint.startsWith("api://")) return "API";
  if (endpoint.startsWith("ext://")) return stripped.toUpperCase();
  return endpoint;
}
