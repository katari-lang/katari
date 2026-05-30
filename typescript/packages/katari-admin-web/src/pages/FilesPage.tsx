import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { FolderOpen, Trash2 } from "lucide-react";
import { useState } from "react";
import toast from "react-hot-toast";
import type { FileWire } from "@/api/types";
import { FileUploadButton, filesQueryKey } from "@/components/domain/FilePicker";
import { Button } from "@/components/ui/Button";
import { CopyableId } from "@/components/ui/CopyableId";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { formatBytes, formatDateTime, relativeTime } from "@/lib/format";
import { useCurrentProjectId } from "@/lib/useCurrentProjectId";

export function FilesPage() {
  const client = useApiClient();
  const queryClient = useQueryClient();
  const projectId = useCurrentProjectId();
  const [deleting, setDeleting] = useState<FileWire | null>(null);

  const { data, isLoading, isError, error } = useQuery({
    queryKey: projectId === null ? ["files", "none"] : filesQueryKey(projectId),
    queryFn: () => client.listFiles(projectId!),
    enabled: projectId !== null,
  });

  const del = useMutation({
    mutationFn: (file: FileWire) => client.deleteFile(projectId!, file.id),
    onSuccess: () => {
      toast.success("File deleted");
      if (projectId !== null) {
        void queryClient.invalidateQueries({ queryKey: filesQueryKey(projectId) });
      }
      setDeleting(null);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Delete failed");
    },
  });

  const files = data?.files ?? [];

  return (
    <div>
      <PageHeader
        title="Files"
        description="Persistent files usable as agent arguments"
        actions={projectId !== null && <FileUploadButton projectId={projectId} />}
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load files."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {files.length === 0 ? (
              <EmptyState
                icon={FolderOpen}
                title="No files"
                description="Upload a file to reference it from a run."
                action={projectId !== null && <FileUploadButton projectId={projectId} />}
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>Name</TH>
                    <TH>Size</TH>
                    <TH>Type</TH>
                    <TH>ID</TH>
                    <TH>Uploaded</TH>
                    <TH className="text-right">Actions</TH>
                  </TR>
                </THead>
                <TBody>
                  {files.map((file) => (
                    <TR key={file.id}>
                      <TD>
                        <span className="text-foreground break-all">
                          {file.displayName ?? <span className="text-subtle-foreground">—</span>}
                        </span>
                      </TD>
                      <TD className="text-muted-foreground">{formatBytes(file.size)}</TD>
                      <TD className="text-xs text-muted-foreground">{file.contentType ?? "—"}</TD>
                      <TD>
                        <CopyableId value={file.id} />
                      </TD>
                      <TD
                        className="text-xs text-muted-foreground"
                        title={formatDateTime(file.createdAt)}
                      >
                        {relativeTime(file.createdAt)}
                      </TD>
                      <TD>
                        <div className="flex justify-end gap-1">
                          <button
                            type="button"
                            onClick={() => setDeleting(file)}
                            className="inline-flex h-8 w-8 items-center justify-center text-muted-foreground transition-colors hover:bg-danger/10 hover:text-danger hover:cursor-pointer"
                            aria-label={`Delete ${file.displayName ?? file.id}`}
                          >
                            <Trash2 className="size-4" />
                          </button>
                        </div>
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </Table>
            )}
          </motion.div>
        )}
      </PageContent>
      <Dialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        title="Delete file"
        size="sm"
      >
        <p className="text-sm text-foreground">
          Delete <code className="font-mono">{deleting?.displayName ?? deleting?.id}</code>? Runs
          that already captured this file keep their copy; new references will fail.
        </p>
        <DialogFooter>
          <Button variant="secondary" onClick={() => setDeleting(null)}>
            Cancel
          </Button>
          <Button
            variant="danger"
            loading={del.isPending}
            onClick={() => deleting !== null && del.mutate(deleting)}
          >
            Delete
          </Button>
        </DialogFooter>
      </Dialog>
    </div>
  );
}
