import { useMemo, useState } from "react";
import { Link } from "react-router-dom";
import { ChevronDown, ChevronRight, Folder, FolderOpen, FileCode } from "lucide-react";
import { cn } from "@/lib/cn";
import type { AgentDefinitionWire } from "@/api/types";

type TreeNode =
  | { kind: "folder"; name: string; path: string; children: TreeNode[] }
  | { kind: "leaf"; name: string; definition: AgentDefinitionWire };

function buildTree(defs: AgentDefinitionWire[]): TreeNode[] {
  const root: TreeNode = { kind: "folder", name: "", path: "", children: [] };
  for (const def of defs) {
    const parts = def.qualifiedName.split(".");
    let cursor = root;
    for (let i = 0; i < parts.length - 1; i += 1) {
      const seg = parts[i]!;
      let next = cursor.kind === "folder"
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
      definition: def,
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
  return [
    ...folders.map((f) => ({ ...f, children: sortTree(f.children) })),
    ...leaves,
  ];
}

type Props = {
  definitions: AgentDefinitionWire[];
  /** Build the per-leaf link target. */
  href: (def: AgentDefinitionWire) => string;
};

export function DefinitionsTree({ definitions, href }: Props) {
  const tree = useMemo(() => buildTree(definitions), [definitions]);
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
    <ul className="text-sm">
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
  return n.kind === "folder" ? `f:${n.path}` : `l:${n.definition.qualifiedName}`;
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
  href: (def: AgentDefinitionWire) => string;
}) {
  // Indent in 1rem steps so nesting is visible without dominating the row.
  const indent = { paddingLeft: `${depth * 1.25 + 0.5}rem` };

  if (node.kind === "folder") {
    const isOpen = openSet.has(node.path);
    return (
      <li>
        <button
          type="button"
          onClick={() => onToggle(node.path)}
          style={indent}
          className="flex w-full items-center gap-1.5 py-1 pr-2 text-left text-foreground transition-colors hover:bg-muted hover:cursor-pointer"
        >
          {isOpen ? (
            <ChevronDown className="size-3.5 text-muted-foreground" />
          ) : (
            <ChevronRight className="size-3.5 text-muted-foreground" />
          )}
          {isOpen ? (
            <FolderOpen className="size-4 text-muted-foreground" />
          ) : (
            <Folder className="size-4 text-muted-foreground" />
          )}
          <span className="font-mono">{node.name}</span>
        </button>
        {isOpen && (
          <ul>
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

  // Leaf — clickable link to definition detail.
  return (
    <li>
      <Link
        to={href(node.definition)}
        style={indent}
        className={cn(
          "flex items-center gap-1.5 py-1 pr-2 text-foreground transition-colors hover:bg-muted",
        )}
      >
        <span className="inline-block w-3.5" aria-hidden />
        <FileCode className="size-4 text-muted-foreground" />
        <span className="font-mono">{node.name}</span>
        {node.definition.description !== undefined &&
          node.definition.description !== "" && (
            <span className="ml-2 truncate text-xs text-subtle-foreground">
              — {node.definition.description}
            </span>
          )}
      </Link>
    </li>
  );
}
