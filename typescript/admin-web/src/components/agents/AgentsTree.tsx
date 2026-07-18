// Hierarchical agent listing: qualified names become a real folder tree (`shop.tools.fetch` nests
// under shop › tools), each folder collapsible, each leaf a two-line row showing the agent's `@"..."`
// description. Which entries reach this tree (the project's own vs. its dependencies) is decided by
// the page, not here.

import { ChevronDown, ChevronRight, FileCode, Folder, FolderOpen } from "lucide-react";
import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import type { AgentEntry } from "../../api/types";
import { cn } from "../../lib/cn";

type TreeNode =
  | { kind: "folder"; name: string; path: string; children: TreeNode[] }
  | { kind: "leaf"; name: string; agent: AgentEntry };

function buildTree(agents: AgentEntry[]): TreeNode[] {
  const root: TreeNode = { kind: "folder", name: "", path: "", children: [] };
  for (const agent of agents) {
    const parts = agent.qualifiedName.split(".");
    let cursor = root;
    for (let index = 0; index < parts.length - 1; index += 1) {
      const segment = parts[index] ?? "";
      let next =
        cursor.kind === "folder"
          ? cursor.children.find(
              (child): child is TreeNode & { kind: "folder" } =>
                child.kind === "folder" && child.name === segment,
            )
          : undefined;
      if (next === undefined) {
        next = {
          kind: "folder",
          name: segment,
          path: parts.slice(0, index + 1).join("."),
          children: [],
        };
        if (cursor.kind === "folder") cursor.children.push(next);
      }
      cursor = next;
    }
    if (cursor.kind !== "folder") continue;
    cursor.children.push({
      kind: "leaf",
      name: parts[parts.length - 1] ?? agent.qualifiedName,
      agent,
    });
  }
  return sortTree(root.children);
}

// Folders first (alphabetical), then leaves (alphabetical) — file-explorer norms.
function sortTree(nodes: TreeNode[]): TreeNode[] {
  const folders = nodes.filter(
    (node): node is TreeNode & { kind: "folder" } => node.kind === "folder",
  );
  const leaves = nodes.filter((node): node is TreeNode & { kind: "leaf" } => node.kind === "leaf");
  folders.sort((left, right) => left.name.localeCompare(right.name));
  leaves.sort((left, right) => left.name.localeCompare(right.name));
  return [
    ...folders.map((folder) => ({ ...folder, children: sortTree(folder.children) })),
    ...leaves,
  ];
}

// Per-level indent (rem), applied inline so nesting depth needs no Tailwind classes.
const INDENT_REM = 1.25;
const ROW_BASE = "flex w-full items-center gap-2 px-3 text-left transition-colors hover:bg-sunken";

export function AgentsTree({
  projectId,
  agents,
  snapshotId,
}: {
  projectId: string;
  agents: AgentEntry[];
  snapshotId?: string;
}) {
  const tree = useMemo(() => buildTree(agents), [agents]);
  // Default every folder open so the operator sees everything at a glance; toggling is local.
  const [open, setOpen] = useState<Set<string>>(() => collectFolderPaths(tree));

  const query = snapshotId === undefined ? "" : `?snapshot=${snapshotId}`;
  const href = (agent: AgentEntry) =>
    `/projects/${projectId}/agents/${encodeURIComponent(agent.qualifiedName)}${query}`;

  function toggle(path: string) {
    setOpen((previous) => {
      const next = new Set(previous);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }

  return (
    <ul className="divide-y divide-edge text-sm">
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

function collectFolderPaths(nodes: TreeNode[]): Set<string> {
  const paths = new Set<string>();
  const walk = (node: TreeNode) => {
    if (node.kind !== "folder") return;
    paths.add(node.path);
    for (const child of node.children) walk(child);
  };
  for (const node of nodes) walk(node);
  return paths;
}

function nodeKey(node: TreeNode): string {
  return node.kind === "folder" ? `f:${node.path}` : `l:${node.agent.qualifiedName}`;
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
  href: (agent: AgentEntry) => string;
}) {
  // Inline indent so arbitrary nesting depth needs no Tailwind classes.
  const indent = { paddingLeft: `${depth * INDENT_REM + 0.75}rem` };

  if (node.kind === "folder") {
    const isOpen = openSet.has(node.path);
    return (
      <li>
        <button
          type="button"
          onClick={() => onToggle(node.path)}
          style={indent}
          className={cn(ROW_BASE, "h-11 pr-3 text-fg")}
        >
          {isOpen ? (
            <ChevronDown className="size-4 shrink-0 text-fg-faint" />
          ) : (
            <ChevronRight className="size-4 shrink-0 text-fg-faint" />
          )}
          {isOpen ? (
            <FolderOpen className="size-4 shrink-0 text-fg-faint" />
          ) : (
            <Folder className="size-4 shrink-0 text-fg-faint" />
          )}
          <span className="font-mono">{node.name}</span>
        </button>
        {isOpen && (
          <ul className="divide-y divide-edge border-t border-edge">
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

  const description = node.agent.description;
  return (
    <li>
      <Link to={href(node.agent)} style={indent} className={cn(ROW_BASE, "h-14 pr-3 text-fg")}>
        {/* Spacer to align the file icon with the folder rows' folder icon (past the chevron). */}
        <span className="inline-block size-4 shrink-0" aria-hidden />
        <FileCode className="size-4 shrink-0 text-accent" />
        <div className="flex min-w-0 flex-1 flex-col">
          <span className="truncate font-mono text-fg">{node.name}</span>
          {description !== "" && (
            <span className="mt-0.5 truncate text-xs text-fg-muted">{description}</span>
          )}
        </div>
      </Link>
    </li>
  );
}
