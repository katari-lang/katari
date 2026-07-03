// Env entries. The list is metadata-only by design: a secret's value is write-only over the API
// (programs read it via `env.get_secret`); a plain entry's value is revealable per row on demand.

import { useQueryClient } from "@tanstack/react-query";
import { Eye, KeyRound, Pencil, Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { useParams } from "react-router-dom";
import { ApiError, api } from "../api/client";
import { useEnv } from "../api/queries";
import { Badge } from "../components/ui/Badge";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { ConfirmDialog, Dialog } from "../components/ui/Dialog";
import { EmptyState } from "../components/ui/EmptyState";
import { Input, Label, Switch } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { Cell, Row, Table } from "../components/ui/Table";
import { formatDateTime } from "../lib/format";
import { useToast } from "../lib/toast";

export function EnvPage() {
  const { projectId = "" } = useParams();
  const env = useEnv(projectId);
  const [editing, setEditing] = useState<{ key: string } | "new" | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);
  const toast = useToast();
  const queryClient = useQueryClient();

  const refresh = () => queryClient.invalidateQueries({ queryKey: ["projects", projectId, "env"] });

  return (
    <>
      <PageHeader
        title="Env"
        description="Configuration your programs read via `env.get` / `env.get_secret`."
        actions={
          <Button variant="primary" onClick={() => setEditing("new")}>
            <Plus className="size-4" /> Add entry
          </Button>
        }
      />
      {env.isPending ? (
        <LoadingBlock />
      ) : (env.data ?? []).length === 0 ? (
        <EmptyState
          icon={KeyRound}
          title="No env entries"
          description="Add configuration or secrets for your programs here."
        />
      ) : (
        <Card>
          <Table headers={["Key", "Value", "Updated", ""]}>
            {(env.data ?? []).map((entry) => (
              <Row key={entry.key}>
                <Cell className="font-mono text-xs font-medium">{entry.key}</Cell>
                <Cell>
                  {entry.isSecret ? (
                    <Badge tone="danger">secret · write-only</Badge>
                  ) : (
                    <RevealValue projectId={projectId} entryKey={entry.key} />
                  )}
                </Cell>
                <Cell className="text-fg-muted">{formatDateTime(entry.updatedAt)}</Cell>
                <Cell className="text-right">
                  <span className="inline-flex gap-1">
                    <Button
                      size="sm"
                      variant="ghost"
                      onClick={() => setEditing({ key: entry.key })}
                    >
                      <Pencil className="size-3.5" />
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => setDeleting(entry.key)}>
                      <Trash2 className="size-3.5" />
                    </Button>
                  </span>
                </Cell>
              </Row>
            ))}
          </Table>
        </Card>
      )}

      {editing !== null && (
        <UpsertDialog
          projectId={projectId}
          initialKey={editing === "new" ? "" : editing.key}
          onClose={() => setEditing(null)}
          onSaved={() => {
            setEditing(null);
            void refresh();
          }}
        />
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        onConfirm={() => {
          if (deleting === null) return;
          api
            .deleteEnvEntry(projectId, deleting)
            .then(() => {
              setDeleting(null);
              void refresh();
            })
            .catch((error: unknown) =>
              toast(error instanceof ApiError ? error.message : "Delete failed.", "error"),
            );
        }}
        title={`Delete ${deleting ?? ""}?`}
        description="Programs reading this key will start failing over to their defaults."
        confirmLabel="Delete"
      />
    </>
  );
}

function RevealValue({ projectId, entryKey }: { projectId: string; entryKey: string }) {
  const [value, setValue] = useState<string | null>(null);
  const toast = useToast();
  if (value !== null) return <span className="font-mono text-xs">{value}</span>;
  return (
    <Button
      size="sm"
      variant="ghost"
      onClick={() =>
        api
          .getEnvEntry(projectId, entryKey)
          .then((entry) => setValue(entry.isSecret ? "" : entry.value))
          .catch(() => toast("Could not read the value.", "error"))
      }
    >
      <Eye className="size-3.5" /> Reveal
    </Button>
  );
}

function UpsertDialog({
  projectId,
  initialKey,
  onClose,
  onSaved,
}: {
  projectId: string;
  initialKey: string;
  onClose: () => void;
  onSaved: () => void;
}) {
  const toast = useToast();
  const [entryKey, setEntryKey] = useState(initialKey);
  const [value, setValue] = useState("");
  const [isSecret, setIsSecret] = useState(false);
  const [busy, setBusy] = useState(false);

  const save = async () => {
    setBusy(true);
    try {
      await api.setEnvEntry(projectId, entryKey, { value, isSecret });
      onSaved();
    } catch (error) {
      toast(error instanceof ApiError ? error.message : "Save failed.", "error");
    } finally {
      setBusy(false);
    }
  };

  return (
    <Dialog open onClose={onClose} title={initialKey === "" ? "Add entry" : `Edit ${initialKey}`}>
      <div className="flex flex-col gap-3">
        <Label text="Key">
          <Input
            value={entryKey}
            onChange={(event) => setEntryKey(event.target.value)}
            disabled={initialKey !== ""}
            placeholder="API_BASE_URL"
          />
        </Label>
        <Label text="Value">
          <Input
            type={isSecret ? "password" : "text"}
            value={value}
            onChange={(event) => setValue(event.target.value)}
          />
        </Label>
        <Switch
          checked={isSecret}
          onChange={setIsSecret}
          label="Secret (write-only, encrypted at rest)"
        />
        <div className="flex justify-end gap-2 pt-1">
          <Button onClick={onClose}>Cancel</Button>
          <Button
            variant="primary"
            disabled={entryKey === ""}
            loading={busy}
            onClick={() => void save()}
          >
            Save
          </Button>
        </div>
      </div>
    </Dialog>
  );
}
