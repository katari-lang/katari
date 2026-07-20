// Store entries: the project's durable key-value tree (`prelude.store`), rendered as the file
// system it behaves as — keys are /-separated paths, so the listing groups them into collapsible
// folders. Values are wire JSON (a program's stored value, redacted where private); the editor
// takes raw JSON, and file handles can only be stored from a program (the API rejects them here).

import { useQueryClient } from "@tanstack/react-query";
import { ChevronDown, ChevronRight, Database, Eye, Pencil, Plus, Trash2 } from "lucide-react";
import { useMemo, useState } from "react";
import { useParams } from "react-router-dom";
import { ApiError, api } from "../api/client";
import { useStore } from "../api/queries";
import type { Json, StoreEntrySummary } from "../api/types";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { ConfirmDialog, Dialog } from "../components/ui/Dialog";
import { EmptyState } from "../components/ui/EmptyState";
import { Input, Label, TextArea } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { ValueBlock } from "../components/values/ValueViewer";
import { formatDateTime } from "../lib/format";
import { useToast } from "../lib/toast";

export function StorePage() {
  const { projectId = "" } = useParams();
  const store = useStore(projectId);
  const [viewing, setViewing] = useState<string | null>(null);
  const [editing, setEditing] = useState<{ key: string } | "new" | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const toast = useToast();
  const queryClient = useQueryClient();

  const refresh = () =>
    queryClient.invalidateQueries({ queryKey: ["projects", projectId, "store"] });

  const tree = useMemo(() => buildTree(store.data ?? []), [store.data]);

  return (
    <>
      <PageHeader
        title="Store"
        description="Durable values your programs read and write via `store.get` / `store.set`."
        actions={
          <Button variant="primary" onClick={() => setEditing("new")}>
            <Plus className="size-4" /> Add entry
          </Button>
        }
      />
      {store.isPending ? (
        <LoadingBlock />
      ) : (store.data ?? []).length === 0 ? (
        <EmptyState
          icon={Database}
          title="No store entries"
          description="A program's `store.set` — or the Add entry button — creates the first one."
        />
      ) : (
        <Card>
          <div className="flex flex-col py-1">
            <TreeLevel
              node={tree}
              depth={0}
              onView={setViewing}
              onEdit={(key) => setEditing({ key })}
              onDelete={setDeleting}
            />
          </div>
        </Card>
      )}

      {viewing !== null && (
        <ViewDialog projectId={projectId} entryKey={viewing} onClose={() => setViewing(null)} />
      )}
      {editing !== null && (
        <EditDialog
          projectId={projectId}
          entryKey={editing === "new" ? null : editing.key}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            refresh();
          }}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        onConfirm={() => {
          if (deleting === null) return;
          api
            .deleteStoreEntry(projectId, deleting)
            .then(() => {
              setDeleting(null);
              refresh();
            })
            .catch((error: unknown) =>
              toast(error instanceof ApiError ? error.message : "Delete failed.", "error"),
            );
        }}
        title={`Delete ${deleting ?? ""}?`}
        description="The entry is removed for every program reading it."
        confirmLabel="Delete"
      />
    </>
  );
}

// ─── the key tree ─────────────────────────────────────────────────────────────

interface TreeNode {
  branches: Map<string, TreeNode>;
  leaves: { name: string; key: string; updatedAt: string }[];
}

function buildTree(entries: StoreEntrySummary[]): TreeNode {
  const root: TreeNode = { branches: new Map(), leaves: [] };
  for (const entry of entries) {
    const segments = entry.key.split("/");
    let node = root;
    for (const segment of segments.slice(0, -1)) {
      let child = node.branches.get(segment);
      if (child === undefined) {
        child = { branches: new Map(), leaves: [] };
        node.branches.set(segment, child);
      }
      node = child;
    }
    const name = segments[segments.length - 1] ?? entry.key;
    node.leaves.push({ name, key: entry.key, updatedAt: entry.updatedAt });
  }
  return root;
}

function TreeLevel({
  node,
  depth,
  onView,
  onEdit,
  onDelete,
}: {
  node: TreeNode;
  depth: number;
  onView: (key: string) => void;
  onEdit: (key: string) => void;
  onDelete: (key: string) => void;
}) {
  const names = [
    ...new Set([...node.branches.keys(), ...node.leaves.map((leaf) => leaf.name)]),
  ].sort();
  return (
    <>
      {names.map((name) => {
        const branch = node.branches.get(name);
        const leaf = node.leaves.find((entry) => entry.name === name);
        return (
          <div key={name}>
            {branch !== undefined && (
              <Branch name={name} depth={depth}>
                <TreeLevel
                  node={branch}
                  depth={depth + 1}
                  onView={onView}
                  onEdit={onEdit}
                  onDelete={onDelete}
                />
              </Branch>
            )}
            {leaf !== undefined && (
              <div
                className="flex items-center gap-2 px-4 py-1.5 hover:bg-sunken"
                style={{ paddingLeft: `${depth * 1.25 + 1}rem` }}
              >
                <button
                  type="button"
                  className="min-w-0 flex-1 truncate text-left font-mono text-xs text-fg"
                  title={leaf.key}
                  onClick={() => onView(leaf.key)}
                >
                  {leaf.name}
                </button>
                <span className="whitespace-nowrap text-xs text-fg-faint">
                  {formatDateTime(leaf.updatedAt)}
                </span>
                <span className="inline-flex items-center gap-1 whitespace-nowrap">
                  <Button size="sm" variant="ghost" onClick={() => onView(leaf.key)}>
                    <Eye className="size-3.5" />
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => onEdit(leaf.key)}>
                    <Pencil className="size-3.5" />
                  </Button>
                  <Button size="sm" variant="ghost" onClick={() => onDelete(leaf.key)}>
                    <Trash2 className="size-3.5" />
                  </Button>
                </span>
              </div>
            )}
          </div>
        );
      })}
    </>
  );
}

function Branch({
  name,
  depth,
  children,
}: {
  name: string;
  depth: number;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useState(true);
  return (
    <div>
      <button
        type="button"
        className="flex w-full items-center gap-1 px-4 py-1.5 text-left text-xs font-medium text-fg-muted hover:bg-sunken"
        style={{ paddingLeft: `${depth * 1.25 + 1}rem` }}
        onClick={() => setOpen((current) => !current)}
      >
        {open ? <ChevronDown className="size-3.5" /> : <ChevronRight className="size-3.5" />}
        <span className="font-mono">{name}/</span>
      </button>
      {open && children}
    </div>
  );
}

// ─── dialogs ──────────────────────────────────────────────────────────────────

function ViewDialog({
  projectId,
  entryKey,
  onClose,
}: {
  projectId: string;
  entryKey: string;
  onClose: () => void;
}) {
  const [value, setValue] = useState<Json | undefined>(undefined);
  const toast = useToast();
  if (value === undefined) {
    api
      .getStoreEntry(projectId, entryKey)
      .then((entry) => setValue(entry.value))
      .catch((error: unknown) => {
        toast(error instanceof ApiError ? error.message : "Read failed.", "error");
        onClose();
      });
  }
  return (
    <Dialog open onClose={onClose} title={entryKey} width="wide">
      {value === undefined ? <LoadingBlock /> : <ValueBlock value={value} projectId={projectId} />}
    </Dialog>
  );
}

function EditDialog({
  projectId,
  entryKey,
  onClose,
  onSaved,
}: {
  projectId: string;
  /** `null` creates a new entry (the key field is editable). */
  entryKey: string | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [key, setKey] = useState(entryKey ?? "");
  const [text, setText] = useState(entryKey === null ? "" : "…");
  const [loaded, setLoaded] = useState(entryKey === null);
  const [busy, setBusy] = useState(false);
  const toast = useToast();

  if (!loaded && entryKey !== null) {
    api
      .getStoreEntry(projectId, entryKey)
      .then((entry) => {
        setText(JSON.stringify(entry.value, null, 2));
        setLoaded(true);
      })
      .catch((error: unknown) => {
        toast(error instanceof ApiError ? error.message : "Read failed.", "error");
        onClose();
      });
  }

  const save = () => {
    let value: Json;
    try {
      value = JSON.parse(text) as Json;
    } catch {
      toast("The value must be valid JSON.", "error");
      return;
    }
    setBusy(true);
    api
      .setStoreEntry(projectId, key, value)
      .then(onSaved)
      .catch((error: unknown) =>
        toast(error instanceof ApiError ? error.message : "Save failed.", "error"),
      )
      .finally(() => setBusy(false));
  };

  return (
    <Dialog
      open
      onClose={onClose}
      title={entryKey === null ? "Add entry" : `Edit ${entryKey}`}
      width="wide"
    >
      <div className="flex flex-col gap-3">
        {entryKey === null && (
          <Label text="Key" hint="a /-separated path, e.g. memos/2026-07">
            <Input
              value={key}
              onChange={(event) => setKey(event.target.value)}
              placeholder="memos/today"
            />
          </Label>
        )}
        <Label text="Value" hint="JSON; a secret written by a program stays redacted here">
          <TextArea
            value={text}
            disabled={!loaded}
            onChange={(event) => setText(event.target.value)}
            className="min-h-48"
          />
        </Label>
        <div className="flex justify-end gap-2 pt-1">
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="primary" disabled={key === "" || !loaded} loading={busy} onClick={save}>
            Save
          </Button>
        </div>
      </div>
    </Dialog>
  );
}
