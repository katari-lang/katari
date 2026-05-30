// File upload control + picker dialog, shared by the Files page and the
// invoke form's `file`-typed argument field.
//
// A `file` value is a persistent `api_files` record; the operator either
// reuses one already uploaded or uploads a new one on the spot. Both paths
// converge on a `FileWire` (which carries its ready-to-use `$ref as:file`
// envelope), so callers never construct a ref by hand.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { File as FileIcon, Upload } from "lucide-react";
import { useRef } from "react";
import toast from "react-hot-toast";
import type { FileWire, ProjectId } from "@/api/types";
import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { EmptyState } from "@/components/ui/EmptyState";
import { Spinner } from "@/components/ui/Spinner";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { formatBytes, relativeTime } from "@/lib/format";

/** React-query key for a project's file list. Shared so an upload from any
 *  surface (page or picker) invalidates every list view. */
export function filesQueryKey(projectId: ProjectId): unknown[] {
  return ["files", projectId];
}

/** Hidden-input upload button. Calls `onUploaded` with the created file. */
export function FileUploadButton({
  projectId,
  onUploaded,
  label = "Upload file",
  variant = "primary",
}: {
  projectId: ProjectId;
  onUploaded?: (file: FileWire) => void;
  label?: string;
  variant?: "primary" | "secondary";
}) {
  const client = useApiClient();
  const queryClient = useQueryClient();
  const inputRef = useRef<HTMLInputElement>(null);

  const upload = useMutation({
    mutationFn: (file: File) => client.uploadFile(projectId, file),
    onSuccess: ({ file }) => {
      toast.success(`Uploaded ${file.displayName ?? file.id}`);
      void queryClient.invalidateQueries({ queryKey: filesQueryKey(projectId) });
      onUploaded?.(file);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Upload failed");
    },
  });

  return (
    <>
      <input
        ref={inputRef}
        type="file"
        className="hidden"
        onChange={(e) => {
          const file = e.target.files?.[0];
          // Reset so re-selecting the same file fires `change` again.
          e.target.value = "";
          if (file !== undefined) upload.mutate(file);
        }}
      />
      <Button
        type="button"
        variant={variant}
        loading={upload.isPending}
        onClick={() => inputRef.current?.click()}
      >
        <Upload className="size-4" />
        {label}
      </Button>
    </>
  );
}

/** Modal that lists a project's files (each selectable) with an inline
 *  upload. Selecting — or uploading — hands the `FileWire` to `onSelect`. */
export function FilePickerDialog({
  projectId,
  open,
  onClose,
  onSelect,
}: {
  projectId: ProjectId;
  open: boolean;
  onClose: () => void;
  onSelect: (file: FileWire) => void;
}) {
  const client = useApiClient();
  const { data, isLoading } = useQuery({
    queryKey: filesQueryKey(projectId),
    queryFn: () => client.listFiles(projectId),
    enabled: open,
  });
  const files = data?.files ?? [];

  const select = (file: FileWire) => {
    onSelect(file);
    onClose();
  };

  return (
    <Dialog
      open={open}
      onClose={onClose}
      title="Select a file"
      description="Pick an existing file or upload a new one."
      size="lg"
    >
      <div className="space-y-4">
        <div className="flex justify-end">
          <FileUploadButton projectId={projectId} onUploaded={select} label="Upload new" />
        </div>
        {isLoading ? (
          <div className="flex justify-center py-8">
            <Spinner />
          </div>
        ) : files.length === 0 ? (
          <EmptyState
            icon={FileIcon}
            title="No files yet"
            description="Upload a file to use it as an argument."
          />
        ) : (
          <ul className="max-h-80 divide-y divide-border overflow-y-auto border border-border">
            {files.map((file) => (
              <li key={file.id}>
                <button
                  type="button"
                  onClick={() => select(file)}
                  className="flex w-full items-center gap-3 px-3 py-2.5 text-left transition-colors hover:bg-muted hover:cursor-pointer"
                >
                  <FileIcon className="size-4 shrink-0 text-muted-foreground" />
                  <span className="min-w-0 flex-1">
                    <span className="block truncate text-sm text-foreground">
                      {file.displayName ?? file.id}
                    </span>
                    <span className="block text-xs text-subtle-foreground">
                      {formatBytes(file.size)}
                      {file.contentType !== undefined ? ` · ${file.contentType}` : ""} ·{" "}
                      {relativeTime(file.createdAt)}
                    </span>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </Dialog>
  );
}
