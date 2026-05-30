// Form field for a `file`-typed argument. The value it produces is the
// `$ref as:file` envelope (a RawValue) the runtime expects; the operator
// never types it — they pick an existing file or upload one through the
// picker dialog, which hands back a `FileWire` carrying its ref.

import { File as FileIcon, X } from "lucide-react";
import { useState } from "react";
import type { FileWire } from "@/api/types";
import { FilePickerDialog } from "@/components/domain/FilePicker";
import { Button } from "@/components/ui/Button";
import { formatBytes } from "@/lib/format";
import { useCurrentProjectId } from "@/lib/useCurrentProjectId";

export function FileField({ value, onChange }: { value: unknown; onChange: (v: unknown) => void }) {
  const projectId = useCurrentProjectId();
  const [picking, setPicking] = useState(false);
  // Remember the picked file so we can show its name / size; the form value
  // itself only carries the ref envelope.
  const [picked, setPicked] = useState<FileWire | null>(null);

  const hasRef =
    value !== null && typeof value === "object" && "$ref" in (value as Record<string, unknown>);

  if (projectId === null) {
    return (
      <p className="border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning">
        File selection requires a project context.
      </p>
    );
  }

  const select = (file: FileWire) => {
    setPicked(file);
    onChange(file.ref);
  };

  return (
    <div>
      {hasRef ? (
        <div className="flex items-center gap-3 border border-border bg-muted/40 px-3 py-2">
          <FileIcon className="size-4 shrink-0 text-muted-foreground" />
          <span className="min-w-0 flex-1">
            <span className="block truncate text-sm text-foreground">
              {picked?.displayName ?? (value as { $ref: { id: string } }).$ref.id}
            </span>
            {picked !== null && (
              <span className="block text-xs text-subtle-foreground">
                {formatBytes(picked.size)}
                {picked.contentType !== undefined ? ` · ${picked.contentType}` : ""}
              </span>
            )}
          </span>
          <Button type="button" variant="ghost" onClick={() => setPicking(true)}>
            Change
          </Button>
          <button
            type="button"
            onClick={() => {
              setPicked(null);
              onChange(null);
            }}
            className="inline-flex h-8 w-8 items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground hover:cursor-pointer"
            aria-label="Clear file"
          >
            <X className="size-4" />
          </button>
        </div>
      ) : (
        <Button type="button" variant="secondary" onClick={() => setPicking(true)}>
          <FileIcon className="size-4" />
          Select file
        </Button>
      )}
      <FilePickerDialog
        projectId={projectId}
        open={picking}
        onClose={() => setPicking(false)}
        onSelect={select}
      />
    </div>
  );
}
