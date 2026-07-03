// Read-only renderer for wire Json values. Understands the runtime's reserved discriminators —
// `$constructor` (tagged data), `$ref` (file handle, downloadable), `$agent` / `$closure`
// (callable references), `$redacted` (a secret withheld at the wire) — and unescapes `$$`-prefixed
// record keys back to their `$` originals.

import { Braces, Download, EyeOff, FileIcon, FunctionSquare } from "lucide-react";
import { useState } from "react";
import { api } from "../../api/client";
import type { Json } from "../../api/types";
import { formatBytes } from "../../lib/format";
import { useToast } from "../../lib/toast";
import { Badge } from "../ui/Badge";
import { CopyButton } from "../ui/Copy";

export function ValueViewer({ value, projectId }: { value: Json; projectId: string }) {
  return (
    <div className="overflow-x-auto font-mono text-xs leading-relaxed">
      <Node value={value} projectId={projectId} />
    </div>
  );
}

/** The value with a copy-as-JSON affordance, for card bodies. */
export function ValueBlock({ value, projectId }: { value: Json; projectId: string }) {
  return (
    <div className="flex items-start justify-between gap-2">
      <ValueViewer value={value} projectId={projectId} />
      <CopyButton value={JSON.stringify(value, null, 2)} label="Copy JSON" />
    </div>
  );
}

function Node({ value, projectId }: { value: Json; projectId: string }) {
  if (value === null) return <span className="text-fg-faint">null</span>;
  if (typeof value === "boolean" || typeof value === "number") {
    return <span className="text-accent">{String(value)}</span>;
  }
  if (typeof value === "string")
    return <span className="text-success">{JSON.stringify(value)}</span>;
  if (Array.isArray(value)) return <ArrayNode items={value} projectId={projectId} />;
  return <ObjectNode fields={value} projectId={projectId} />;
}

function ArrayNode({ items, projectId }: { items: Json[]; projectId: string }) {
  if (items.length === 0) return <span>[]</span>;
  return (
    <Collapsible preview={`[ ${items.length} item${items.length === 1 ? "" : "s"} ]`}>
      <div className="flex flex-col border-l border-edge pl-4">
        {items.map((item, index) => (
          // Order is the identity of a JSON array element.
          // biome-ignore lint/suspicious/noArrayIndexKey: positional data
          <div key={index} className="flex gap-2">
            <span className="text-fg-faint">{index}:</span>
            <Node value={item} projectId={projectId} />
          </div>
        ))}
      </div>
    </Collapsible>
  );
}

function ObjectNode({ fields, projectId }: { fields: { [key: string]: Json }; projectId: string }) {
  const special = specialNode(fields, projectId);
  if (special !== null) return special;
  const entries = Object.entries(fields);
  if (entries.length === 0) return <span>{"{}"}</span>;
  return (
    <Collapsible preview={`{ ${entries.length} field${entries.length === 1 ? "" : "s"} }`}>
      <div className="flex flex-col border-l border-edge pl-4">
        {entries.map(([key, child]) => (
          <div key={key} className="flex gap-2">
            <span className="text-fg-muted">{unescapeKey(key)}:</span>
            <Node value={child} projectId={projectId} />
          </div>
        ))}
      </div>
    </Collapsible>
  );
}

/** One leading `$` of a `$$…` key is the wire escape; a lone `$…` key is a literal. */
function unescapeKey(key: string): string {
  return key.startsWith("$$") ? key.slice(1) : key;
}

function specialNode(fields: { [key: string]: Json }, projectId: string) {
  if (fields.$redacted === true) {
    return (
      <Badge tone="danger">
        <EyeOff className="size-3" /> redacted
      </Badge>
    );
  }
  if (typeof fields.$constructor === "string") {
    return (
      <span className="inline-flex items-start gap-2">
        <Badge tone="info">
          <Braces className="size-3" /> {fields.$constructor}
        </Badge>
        <Node value={fields.value ?? null} projectId={projectId} />
      </span>
    );
  }
  if (typeof fields.$ref === "string") {
    return (
      <FileChip
        projectId={projectId}
        blobId={fields.$ref}
        size={typeof fields.size === "number" ? fields.size : null}
        contentType={typeof fields.contentType === "string" ? fields.contentType : null}
      />
    );
  }
  if (typeof fields.$agent === "string") {
    return (
      <Badge tone="info">
        <FunctionSquare className="size-3" /> agent {fields.$agent}
      </Badge>
    );
  }
  if (typeof fields.$closure === "number") {
    return (
      <Badge tone="info">
        <FunctionSquare className="size-3" /> closure {String(fields.module ?? "")}#
        {fields.$closure}
      </Badge>
    );
  }
  return null;
}

function FileChip({
  projectId,
  blobId,
  size,
  contentType,
}: {
  projectId: string;
  blobId: string;
  size: number | null;
  contentType: string | null;
}) {
  const toast = useToast();
  const [busy, setBusy] = useState(false);
  const download = async () => {
    setBusy(true);
    try {
      const blob = await api.downloadFile(projectId, blobId);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = blobId;
      anchor.click();
      URL.revokeObjectURL(url);
    } catch {
      toast("Download failed — the file may have been reclaimed.", "error");
    } finally {
      setBusy(false);
    }
  };
  return (
    <span className="inline-flex items-center gap-1">
      <Badge tone="neutral">
        <FileIcon className="size-3" />
        file{size !== null && ` · ${formatBytes(size)}`}
        {contentType !== null && ` · ${contentType}`}
      </Badge>
      <button
        type="button"
        title="Download"
        disabled={busy}
        onClick={() => void download()}
        className="rounded p-1 text-fg-faint transition-colors hover:bg-sunken hover:text-fg disabled:opacity-50"
      >
        <Download className="size-3.5" />
      </button>
    </span>
  );
}

function Collapsible({ preview, children }: { preview: string; children: React.ReactNode }) {
  const [open, setOpen] = useState(true);
  return (
    <div className="flex flex-col">
      <button
        type="button"
        onClick={() => setOpen(!open)}
        className="self-start text-fg-faint transition-colors hover:text-fg"
      >
        {open ? "▾" : `▸ ${preview}`}
      </button>
      {open && children}
    </div>
  );
}
