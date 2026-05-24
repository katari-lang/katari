import { useMutation, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { Button } from "@/components/ui/Button";
import type { EnvEntry } from "@/api/types";

type Props = {
  open: boolean;
  onClose: () => void;
  target: EnvEntry | null;
};

export function EnvDeleteDialog({ open, onClose, target }: Props) {
  const client = useApiClient();
  const queryClient = useQueryClient();

  const mutation = useMutation({
    mutationFn: async () => {
      if (target === null) throw new Error("No target");
      await client.deleteEnv(target.key);
    },
    onSuccess: () => {
      toast.success("Entry deleted");
      void queryClient.invalidateQueries({ queryKey: ["env"] });
      onClose();
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed");
    },
  });

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Delete env entry"
      description="This removes the key from runtime configuration immediately."
      size="sm"
    >
      <p className="text-sm text-foreground">
        Delete <code className="font-mono">{target?.key}</code>?
      </p>
      <DialogFooter>
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button
          variant="danger"
          onClick={() => mutation.mutate()}
          loading={mutation.isPending}
        >
          Delete
        </Button>
      </DialogFooter>
    </Dialog>
  );
}
