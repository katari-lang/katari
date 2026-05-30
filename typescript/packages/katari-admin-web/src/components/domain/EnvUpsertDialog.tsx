import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";
import toast from "react-hot-toast";
import type { EnvEntry, ProjectId } from "@/api/types";
import { Button } from "@/components/ui/Button";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { Switch } from "@/components/ui/Switch";
import { TextArea } from "@/components/ui/TextArea";
import { useApiClient } from "@/contexts/ApiKeyContext";

type Props = {
  projectId: ProjectId;
  open: boolean;
  onClose: () => void;
  /** When given, the dialog enters "edit" mode (key locked). */
  editing: EnvEntry | null;
};

const KEY_PATTERN = /^[A-Za-z0-9_.-]+$/;

export function EnvUpsertDialog({ projectId, open, onClose, editing }: Props) {
  const client = useApiClient();
  const queryClient = useQueryClient();
  const [key, setKey] = useState("");
  const [value, setValue] = useState("");
  const [isSecret, setIsSecret] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    if (editing !== null) {
      setKey(editing.key);
      setValue(editing.isSecret ? "" : editing.value);
      setIsSecret(editing.isSecret);
    } else {
      setKey("");
      setValue("");
      setIsSecret(false);
    }
    setError(null);
  }, [open, editing]);

  const mutation = useMutation({
    mutationFn: async () => {
      if (!KEY_PATTERN.test(key)) {
        throw new Error("Key must match [A-Za-z0-9_.-]+");
      }
      await client.upsertEnv(projectId, { key, value, isSecret });
    },
    onSuccess: () => {
      toast.success(editing !== null ? "Entry updated" : "Entry created");
      void queryClient.invalidateQueries({ queryKey: ["env", projectId] });
      onClose();
    },
    onError: (err) => {
      const message = err instanceof Error ? err.message : "Failed";
      setError(message);
      toast.error(message);
    },
  });

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title={editing !== null ? "Edit env entry" : "Add env entry"}
      description={isSecret ? "Encrypted at rest." : "Stored as plaintext."}
    >
      <form
        onSubmit={(e) => {
          e.preventDefault();
          mutation.mutate();
        }}
        className="space-y-4"
      >
        <div className="space-y-1.5">
          <Label htmlFor="env-key">Key</Label>
          <Input
            id="env-key"
            value={key}
            onChange={(e) => setKey(e.target.value)}
            disabled={editing !== null}
            placeholder="ENV_KEY"
            autoComplete="off"
            spellCheck={false}
            required
          />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="env-value">Value</Label>
          <TextArea
            id="env-value"
            value={value}
            onChange={(e) => setValue(e.target.value)}
            placeholder={
              editing?.isSecret ? "New secret value (replaces the existing one)" : "value"
            }
            rows={4}
            autoComplete="off"
            spellCheck={false}
            required
          />
        </div>
        <div className="flex items-center justify-between  border border-border bg-muted/40 px-3 py-2.5">
          <div>
            <Label className="cursor-pointer">Secret</Label>
            <p className="mt-0.5 text-xs text-subtle-foreground">
              Reads return <code className="font-mono">{`<redacted>`}</code>.
            </p>
          </div>
          <Switch checked={isSecret} onChange={setIsSecret} ariaLabel="Mark as secret" />
        </div>
        {error !== null && (
          <p className=" border border-danger/30 bg-danger/10 px-3 py-2 text-sm text-danger">
            {error}
          </p>
        )}
        <DialogFooter>
          <Button type="button" variant="secondary" onClick={onClose}>
            Cancel
          </Button>
          <Button type="submit" variant="primary" loading={mutation.isPending}>
            {editing !== null ? "Save" : "Create"}
          </Button>
        </DialogFooter>
      </form>
    </Dialog>
  );
}
