import { ChevronDown, ChevronRight, FileCode, Folder, FolderOpen } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import type { AgentWire } from "@/api/types";

type TreeNode =
  | { kind: "folder"; name: string; path: string; children: TreeNode[] }
  | { kind: "leaf"; name: string; agent: AgentWire };

function buildTree(agents: AgentWire[]): TreeNode[] {
  const root: TreeNode = { kind: "folder", name: "", path: "", children: [] };
  for (const agent of agents) {
    const parts = agent.qualifiedName.split(".");
    let cursor = root;
    for (let i = 0; i < parts.length - 1; i += 1) {
      const seg = parts[i]!;
      let next =
        cursor.kind === "folder"
          ? cursor.children.find(
              (c): c is TreeNode & { kind: "folder" } => c.kind === "folder" && c.name === seg,
            )
          : undefined;
      if (next === undefined) {
        next = {
          kind: "folder",
          name: seg,
          path: parts.slice(0, i + 1).join("."),
          children: [],
        };
        if (cursor.kind === "folder") cursor.children.push(next);
      }
      cursor = next;
    }
    if (cursor.kind !== "folder") continue;
    cursor.children.push({
      kind: "leaf",
      name: parts[parts.length - 1]!,
      agent,
    });
  }
  return sortTree(root.kind === "folder" ? root.children : []);
}

// Folders first (alpha), then leaves (alpha). Matches file-explorer norms.
function sortTree(nodes: TreeNode[]): TreeNode[] {
  const folders = nodes.filter((n): n is TreeNode & { kind: "folder" } => n.kind === "folder");
  const leaves = nodes.filter((n): n is TreeNode & { kind: "leaf" } => n.kind === "leaf");
  folders.sort((a, b) => a.name.localeCompare(b.name));
  leaves.sort((a, b) => a.name.localeCompare(b.name));
  return [...folders.map((f) => ({ ...f, children: sortTree(f.children) })), ...leaves];
}

type Props = {
  agents: AgentWire[];
  /** Build the per-leaf link target. */
  href: (agent: AgentWire) => string;
};

// Row height matched to the rest of the admin tables (= py-2.5, ~40px
// without description, ~52px with). Per-row hairline border keeps the
// "list of clickable rows" feel without leaning on background contrast.
const ROW_BASE =
  "flex w-full items-center gap-2 px-3 py-2.5 text-left transition-colors hover:bg-muted/50";
// Indent per nesting level (rem). Used in inline style so depth can be
// arbitrarily nested without Tailwind needing to know about it.
const INDENT_REM = 1.25;

export function AgentsTree({ agents, href }: Props) {
  const tree = useMemo(() => buildTree(agents), [agents]);
  // Default-open every folder so the operator sees everything immediately.
  // The folder state is stored as a Set keyed by dotted path; toggling is
  // local — no need to persist.
  const initialOpen = useMemo(() => collectAllFolderPaths(tree), [tree]);
  const [open, setOpen] = useState<Set<string>>(initialOpen);

  function toggle(path: string) {
    setOpen((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }

  return (
    <ul className="divide-y divide-border text-sm">
      {tree.map((node) => (
        <TreeRow
          key={nodeKey(node)}
          node={node}
          depth={0}
          openSet={open}
          onToggle={toggle}
          href={href}
        />
      ))}
    </ul>
  );
}

function collectAllFolderPaths(nodes: TreeNode[]): Set<string> {
  const out = new Set<string>();
  function walk(n: TreeNode) {
    if (n.kind !== "folder") return;
    out.add(n.path);
    for (const c of n.children) walk(c);
  }
  for (const n of nodes) walk(n);
  return out;
}

function nodeKey(n: TreeNode): string {
  return n.kind === "folder" ? `f:${n.path}` : `l:${n.agent.qualifiedName}`;
}

function TreeRow({
  node,
  depth,
  openSet,
  onToggle,
  href,
}: {
  node: TreeNode;
  depth: number;
  openSet: Set<string>;
  onToggle: (path: string) => void;
  href: (def: AgentWire) => string;
}) {
  const indent = { paddingLeft: `${depth * INDENT_REM + 0.75}rem` };

  if (node.kind === "folder") {
    const isOpen = openSet.has(node.path);
    return (
      <li>
        <button
          type="button"
          onClick={() => onToggle(node.path)}
          style={indent}
          className={`${ROW_BASE} items-center pr-3 text-foreground hover:cursor-pointer h-12`}
        >
          {isOpen ? (
            <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
          ) : (
            <ChevronRight className="size-4 shrink-0 text-muted-foreground" />
          )}
          {isOpen ? (
            <FolderOpen className="size-4 shrink-0 text-muted-foreground" />
          ) : (
            <Folder className="size-4 shrink-0 text-muted-foreground" />
          )}
          <span className="font-mono">{node.name}</span>
        </button>
        {isOpen && (
          <ul className="divide-y divide-border border-t border-border">
            {node.children.map((child) => (
              <TreeRow
                key={nodeKey(child)}
                node={child}
                depth={depth + 1}
                openSet={openSet}
                onToggle={onToggle}
                href={href}
              />
            ))}
          </ul>
        )}
      </li>
    );
  }

  // Leaf: file-style row with name on top + description below. Larger
  // click target than the previous single-line version.
  const desc = node.agent.description;
  return (
    <li>
      <Link
        to={href(node.agent)}
        style={indent}
        className={`${ROW_BASE} pr-3 text-foreground h-16`}
      >
        {/* Spacer to align with folder rows' chevron column. */}
        <span className="inline-block size-4 shrink-0" aria-hidden />
        <FileCode className="mt-0.5 size-4 shrink-0 text-muted-foreground" />
        <div className="flex min-w-0 flex-1 flex-col">
          <span className="truncate font-mono text-foreground">{node.name}</span>
          {desc !== undefined && desc !== "" && (
            <span className="mt-0.5 truncate text-xs text-muted-foreground">{desc}</span>
          )}
        </div>
      </Link>
    </li>
  );
}
