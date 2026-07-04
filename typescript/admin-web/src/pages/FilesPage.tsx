import { useQueryClient } from "@tanstack/react-query";
import { Download, FileIcon, Trash2, Upload } from "lucide-react";
import { useRef, useState } from "react";
import { useParams } from "react-router-dom";
import { ApiError, api } from "../api/client";
import { useFiles } from "../api/queries";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { CopyableId } from "../components/ui/Copy";
import { ConfirmDialog } from "../components/ui/Dialog";
import { EmptyState } from "../components/ui/EmptyState";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { Cell, Row, Table } from "../components/ui/Table";
import { formatBytes } from "../lib/format";
import { useToast } from "../lib/toast";

export function FilesPage() {
  const { projectId = "" } = useParams();
  const files = useFiles(projectId);
  const toast = useToast();
  const queryClient = useQueryClient();
  const inputRef = useRef<HTMLInputElement>(null);
  const [uploading, setUploading] = useState(false);
  const [deleting, setDeleting] = useState<string | null>(null);

  const upload = async (file: File) => {
    setUploading(true);
    try {
      await api.uploadFile(projectId, file);
      await queryClient.invalidateQueries({ queryKey: ["projects", projectId, "files"] });
      toast(`Uploaded ${file.name}.`);
    } catch {
      toast("Upload failed.", "error");
    } finally {
      setUploading(false);
    }
  };

  const download = async (fileId: string) => {
    try {
      const blob = await api.downloadFile(projectId, fileId);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = fileId;
      anchor.click();
      URL.revokeObjectURL(url);
    } catch {
      toast("Download failed.", "error");
    }
  };

  const uploadButton = (
    <>
      <input
        ref={inputRef}
        type="file"
        className="hidden"
        onChange={(event) => {
          const file = event.target.files?.[0];
          if (file !== undefined) void upload(file);
          event.target.value = "";
        }}
      />
      <Button variant="primary" loading={uploading} onClick={() => inputRef.current?.click()}>
        <Upload className="size-4" /> Upload
      </Button>
    </>
  );

  return (
    <>
      <PageHeader
        title="Files"
        description="Blobs the project holds; programs receive them as `file` values."
        actions={uploadButton}
      />
      {files.isPending ? (
        <LoadingBlock />
      ) : (files.data ?? []).length === 0 ? (
        <EmptyState
          icon={FileIcon}
          title="No files"
          description="Upload one to pass it to an agent."
        />
      ) : (
        <Card>
          <Table headers={["Id", "Size", "Content type", "Kind", ""]}>
            {(files.data ?? []).map((file) => (
              <Row key={file.id}>
                <Cell>
                  <CopyableId id={file.id} />
                </Cell>
                <Cell className="text-fg-muted">{formatBytes(file.size)}</Cell>
                <Cell className="font-mono text-xs text-fg-muted">{file.contentType ?? "—"}</Cell>
                <Cell className="text-fg-muted">{file.semanticKind}</Cell>
                <Cell className="text-right">
                  <span className="inline-flex gap-1">
                    <Button size="sm" variant="ghost" onClick={() => void download(file.id)}>
                      <Download className="size-3.5" /> Download
                    </Button>
                    <Button size="sm" variant="ghost" onClick={() => setDeleting(file.id)}>
                      <Trash2 className="size-3.5" />
                    </Button>
                  </span>
                </Cell>
              </Row>
            ))}
          </Table>
        </Card>
      )}
      <ConfirmDialog
        open={deleting !== null}
        onClose={() => setDeleting(null)}
        onConfirm={() => {
          if (deleting === null) return;
          api
            .deleteFile(projectId, deleting)
            .then(() => {
              setDeleting(null);
              void queryClient.invalidateQueries({ queryKey: ["projects", projectId, "files"] });
            })
            .catch((error: unknown) =>
              toast(error instanceof ApiError ? error.message : "Delete failed.", "error"),
            );
        }}
        title="Delete this file?"
        description="A run still referencing it will read it as gone."
        confirmLabel="Delete"
      />
    </>
  );
}
