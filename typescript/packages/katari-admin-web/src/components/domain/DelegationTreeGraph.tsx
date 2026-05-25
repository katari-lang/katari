import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { motion } from "framer-motion";
import { ArrowDown, Maximize2, Minus, Plus } from "lucide-react";
import { cn } from "@/lib/cn";
import { RunStatusBadge } from "./RunStatusBadge";
import type { DelegationTreeNode } from "@/api/types";

const MIN_SCALE = 0.3;
const MAX_SCALE = 2;
const SCALE_STEP = 0.15;
/** Wheel events deliver tiny `deltaY` values on trackpads; scale them
 * down so a continuous swipe doesn't fly past the scale clamps. */
const WHEEL_TO_SCALE = 0.0015;
/** Viewport height in px (= max-h-150 in Tailwind v4 = 600px). */
const VIEWPORT_HEIGHT = 600;

/**
 * Render a delegation tree as a vertical layout: root at top, children
 * fanned out below, each branch recursively a sub-tree.
 *
 * The viewport is a Figma-style infinite canvas:
 *   - **wheel-to-zoom** anchored at the viewport centre
 *   - **drag-to-pan**   with a `translate(...)` transform (no native scroll
 *     bars; the world is one big `transform: translate scale`)
 *   - **no overflow scroll** — the container is `overflow-hidden` and the
 *     content can be panned freely in either direction.
 *   - **slack pan limits** so the user can drag the tree until it's
 *     half-clipped against either edge before bumping into the soft clamp.
 */
export function DelegationTreeGraph({ root }: { root: DelegationTreeNode }) {
  const [scale, setScale] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const viewportRef = useRef<HTMLDivElement>(null);
  const contentRef = useRef<HTMLDivElement>(null);

  // Measure the content's natural (un-scaled) size so we can clamp the
  // pan within "half-tree clipped" bounds. ResizeObserver tracks the
  // inner element so a growing / shrinking tree (= polling new nodes)
  // updates the limits without manual refresh.
  const [contentSize, setContentSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = contentRef.current;
    if (el === null) return;
    const ro = new ResizeObserver((entries) => {
      const e = entries[0];
      if (e === undefined) return;
      setContentSize({ w: e.contentRect.width, h: e.contentRect.height });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Reset zoom returns to (scale=1, pan=0). On first mount the tree is
  // already centred (= transform-origin center of an absolute-centred
  // inner div), so no scroll-equivalent setup is needed.
  const resetView = () => {
    setScale(1);
    setPan({ x: 0, y: 0 });
  };

  // Wheel-to-zoom. Attached via addEventListener with passive: false
  // because React's synthetic `onWheel` is passive by default and
  // can't preventDefault() (= the browser would otherwise vertically
  // scroll the surrounding page along with us).
  useEffect(() => {
    const vp = viewportRef.current;
    if (vp === null) return;
    const onWheel = (e: WheelEvent) => {
      e.preventDefault();
      setScale((s) => {
        const next = s - e.deltaY * WHEEL_TO_SCALE;
        return clamp(next, MIN_SCALE, MAX_SCALE);
      });
    };
    vp.addEventListener("wheel", onWheel, { passive: false });
    return () => vp.removeEventListener("wheel", onWheel);
  }, []);

  // Drag-to-pan. Mousedown lives on the viewport; mousemove + mouseup
  // bind to window so the drag continues even when the cursor leaves
  // the viewport (matches Figma / Excalidraw feel).
  const panStart = useRef<
    { x: number; y: number; px: number; py: number } | null
  >(null);
  const [isPanning, setIsPanning] = useState(false);

  const onMouseDown = (e: React.MouseEvent<HTMLDivElement>) => {
    if ((e.target as HTMLElement).closest("button") !== null) return;
    panStart.current = {
      x: e.clientX,
      y: e.clientY,
      px: pan.x,
      py: pan.y,
    };
    setIsPanning(true);
    e.preventDefault();
  };

  useEffect(() => {
    if (!isPanning) return;
    const onMove = (e: MouseEvent) => {
      const start = panStart.current;
      if (start === null) return;
      const nextX = start.px + (e.clientX - start.x);
      const nextY = start.py + (e.clientY - start.y);
      setPan(clampPan(nextX, nextY, contentSize, scale, viewportRef.current));
    };
    const onUp = () => {
      setIsPanning(false);
      panStart.current = null;
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    return () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
    };
  }, [isPanning, contentSize, scale]);

  return (
    <div className="relative">
      <div className="pointer-events-none absolute right-2 top-2 z-10 flex gap-1">
        <ZoomButton
          icon={Minus}
          onClick={() =>
            setScale((s) => clamp(s - SCALE_STEP, MIN_SCALE, MAX_SCALE))
          }
          ariaLabel="Zoom out"
        />
        <ZoomButton
          icon={Maximize2}
          onClick={resetView}
          ariaLabel="Reset view"
          label={`${Math.round(scale * 100)}%`}
        />
        <ZoomButton
          icon={Plus}
          onClick={() =>
            setScale((s) => clamp(s + SCALE_STEP, MIN_SCALE, MAX_SCALE))
          }
          ariaLabel="Zoom in"
        />
      </div>
      <div
        ref={viewportRef}
        onMouseDown={onMouseDown}
        className={cn(
          "relative overflow-hidden border border-border bg-muted/20 select-none",
          isPanning ? "cursor-grabbing" : "cursor-grab",
        )}
        style={{ height: VIEWPORT_HEIGHT }}
      >
        <div
          ref={contentRef}
          className="absolute left-1/2 top-1/2 origin-center"
          style={{
            transform: `translate(calc(-50% + ${pan.x}px), calc(-50% + ${pan.y}px)) scale(${scale})`,
          }}
        >
          <div className="flex flex-col items-center gap-2 px-4 py-4">
            <TreeNode node={root} depth={0} />
          </div>
        </div>
      </div>
    </div>
  );
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, +v.toFixed(2)));
}

/**
 * Soft pan clamp: allow the user to drag until half of the tree is
 * clipped against the corresponding viewport edge. Returns the input
 * coords clamped to that range. With contentSize === 0 (= not measured
 * yet) we just pass through, so the early frames don't snap to (0,0).
 */
function clampPan(
  x: number,
  y: number,
  contentSize: { w: number; h: number },
  scale: number,
  vp: HTMLDivElement | null,
): { x: number; y: number } {
  if (vp === null || contentSize.w === 0 || contentSize.h === 0) {
    return { x, y };
  }
  // Effective on-screen tree size at the current zoom.
  const treeW = contentSize.w * scale;
  const treeH = contentSize.h * scale;
  // Allow panning so that the tree centre can move all the way to the
  // viewport edge (= at that limit the far side of the tree is half
  // visible, the near side has rolled off-screen).
  const maxX = (vp.clientWidth + treeW) / 2;
  const maxY = (vp.clientHeight + treeH) / 2;
  return {
    x: Math.max(-maxX, Math.min(maxX, x)),
    y: Math.max(-maxY, Math.min(maxY, y)),
  };
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
        "min-w-45 border border-border bg-background px-3 py-2 text-left",
        node.state === "running" && "border-info/40",
        node.state === "cancelling" && "border-warning/40",
        node.state === "error" && "border-danger/40",
      )}
    >
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs uppercase tracking-wider text-subtle-foreground">
          {ownerLabel}
        </span>
        <RunStatusBadge state={node.state} />
      </div>
      <div className="mt-1 font-mono text-xs text-foreground">
        {node.qualifiedName ?? node.agentDefId}
      </div>
      {node.name !== undefined && (
        <div className="mt-0.5 text-xs text-subtle-foreground">
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
