import { useLayoutEffect, useRef, useState } from "react";
import { motion } from "framer-motion";
import { ArrowDown, Maximize2, Minus, Plus } from "lucide-react";
import { cn } from "@/lib/cn";
import { RunStatusBadge } from "./RunStatusBadge";
import type { DelegationTreeNode } from "@/api/types";

const MIN_SCALE = 0.3;
const MAX_SCALE = 2;
const SCALE_STEP = 0.15;

/**
 * Render a delegation tree as a vertical layout: root at top, children
 * fanned out below, each branch recursively a sub-tree. Edges are simple
 * downward arrows — no React Flow / dagre for v0.1.0 (= keep the bundle
 * size and code surface small).
 *
 * Viewport: a scrollable container at fixed max-height with a CSS
 * `transform: scale(...)` zoom. `transform-origin: top left` keeps the
 * root in place when zooming. Buttons in the top-right corner step the
 * scale; horizontal / vertical scrollbars catch overflow when zoomed in
 * past the container size.
 */
export function DelegationTreeGraph({ root }: { root: DelegationTreeNode }) {
  const [scale, setScale] = useState(1);
  const viewportRef = useRef<HTMLDivElement>(null);

  // Center the horizontal scroll position whenever the zoom changes.
  // For content that fits the viewport, `flex justify-center` on the
  // inner row centers it as a no-op; once content overflows, scrollLeft
  // = overflow / 2 starts the user in the middle so they can slide
  // either direction. rAF defers the read until the scaled transform
  // has been laid out.
  useLayoutEffect(() => {
    const vp = viewportRef.current;
    if (vp === null) return;
    const id = requestAnimationFrame(() => {
      const overflow = vp.scrollWidth - vp.clientWidth;
      if (overflow > 0) vp.scrollLeft = overflow / 2;
    });
    return () => cancelAnimationFrame(id);
  }, [scale]);

  return (
    <div className="relative">
      <div className="pointer-events-none absolute right-2 top-2 z-10 flex gap-1">
        <ZoomButton
          icon={Minus}
          onClick={() =>
            setScale((s) => Math.max(MIN_SCALE, +(s - SCALE_STEP).toFixed(2)))
          }
          ariaLabel="Zoom out"
        />
        <ZoomButton
          icon={Maximize2}
          onClick={() => setScale(1)}
          ariaLabel="Reset zoom"
          label={`${Math.round(scale * 100)}%`}
        />
        <ZoomButton
          icon={Plus}
          onClick={() =>
            setScale((s) => Math.min(MAX_SCALE, +(s + SCALE_STEP).toFixed(2)))
          }
          ariaLabel="Zoom in"
        />
      </div>
      <div
        ref={viewportRef}
        className="max-h-150 overflow-auto border border-border bg-muted/20"
      >
        <div className="flex w-max min-w-full justify-center">
          <div
            className="origin-top-left"
            style={{ transform: `scale(${scale})` }}
          >
            <div className="flex flex-col items-center gap-2 px-4 py-4">
              <TreeNode node={root} depth={0} />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function ZoomButton({
  icon: Icon,
  onClick,
  ariaLabel,
  label,
}: {
  icon: React.ComponentType<{ className?: string }>;
  onClick: () => void;
  ariaLabel: string;
  label?: string;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel}
      className="pointer-events-auto inline-flex h-7 items-center gap-1 border border-border bg-background px-2 text-xs text-foreground transition-colors hover:bg-muted"
    >
      <Icon className="size-3.5" />
      {label !== undefined && <span>{label}</span>}
    </button>
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
