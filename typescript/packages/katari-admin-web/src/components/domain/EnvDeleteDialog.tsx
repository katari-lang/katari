import { useMutation, useQueryClient } from "@tanstack/react-query";
import toast from "react-hot-toast";
import type { EnvEntry } from "@/api/types";
import { Button } from "@/components/ui/Button";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { useApiClient } from "@/contexts/ApiKeyContext";

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
      toast.error(err instanceof Error ? err.message : "Delete failed");
    },
  });

  return (
    <Dialog open={open} onClose={onClose} title="Delete env entry" size="sm">
      <p className="text-sm text-foreground">
        Delete <code className="font-mono">{target?.key}</code>?
      </p>
      <DialogFooter>
        <Button variant="secondary" onClick={onClose}>
          Cancel
        </Button>
        <Button variant="danger" onClick={() => mutation.mutate()} loading={mutation.isPending}>
          Delete
        </Button>
      </DialogFooter>
    </Dialog>
  );
}
