// Read-only renderer for wire Json values. The variant dispatch (the reserved `$katari_` keys) comes from
// `@katari-lang/types/wire` — the same single definition the runtime codec and the FFI port encode
// against — so this viewer can never drift from what the runtime actually emits.
//
// Nesting always grows straight down with a fixed indent: a value's `label` (an object key, an array
// index, or a constructor name) sits on the container's header line, and the body indents one step
// from that header's left edge — never to the right of the label, so deep structures don't stair-step
// off the page.

import {
  AGENT_KEY,
  CLOSURE_KEY,
  CONSTRUCTOR_KEY,
  FILE_KEY,
  MODULE_KEY,
  VALUE_KEY,
  wireKindOf,
} from "@katari-lang/types";
import { Braces, Download, EyeOff, FileIcon, FunctionSquare } from "lucide-react";
import { type ReactNode, useState } from "react";
import { api } from "../../api/client";
import type { Json } from "../../api/types";
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

/** A value, optionally prefixed by `label` (an object key / array index). Scalars render inline after
 *  the label; containers put the label on their header line and indent their body straight down. */
function Node({ value, projectId, label }: { value: Json; projectId: string; label?: ReactNode }) {
  if (value === null) {
    return (
      <Inline label={label}>
        <span className="text-fg-faint">null</span>
      </Inline>
    );
  }
  if (typeof value === "boolean" || typeof value === "number") {
    return (
      <Inline label={label}>
        <span className="text-accent">{String(value)}</span>
      </Inline>
    );
  }
  if (typeof value === "string") {
    return (
      <Inline label={label}>
        <span className="text-success">{JSON.stringify(value)}</span>
      </Inline>
    );
  }
  if (Array.isArray(value)) return <ArrayNode items={value} projectId={projectId} label={label} />;
  return <ObjectNode fields={value} projectId={projectId} label={label} />;
}

/** A leaf value on one line: `label value`, or just the value when unlabelled. */
function Inline({ label, children }: { label?: ReactNode; children: ReactNode }) {
  if (label === undefined) return <>{children}</>;
  return (
    <div className="flex gap-2">
      {label}
      {children}
    </div>
  );
}

/** A collapsible container: the `label` + toggle on the header line, the children indented one fixed
 *  step below it (a left border marks the level). */
function Container({
  label,
  preview,
  children,
}: {
  label?: ReactNode;
  preview: string;
  children: ReactNode;
}) {
  const [open, setOpen] = useState(true);
  return (
    <div className="flex flex-col">
      <div className="flex items-center gap-2">
        {label}
        <button
          type="button"
          onClick={() => setOpen(!open)}
          className="text-fg-faint transition-colors hover:text-fg"
        >
          {open ? "▾" : `▸ ${preview}`}
        </button>
      </div>
      {open && <div className="flex flex-col border-l border-edge pl-4">{children}</div>}
    </div>
  );
}

function ArrayNode({
  items,
  projectId,
  label,
}: {
  items: Json[];
  projectId: string;
  label?: ReactNode;
}) {
  if (items.length === 0) {
    return (
      <Inline label={label}>
        <span>[]</span>
      </Inline>
    );
  }
  return (
    <Container label={label} preview={`[ ${items.length} item${items.length === 1 ? "" : "s"} ]`}>
      {items.map((item, index) => (
        <Node
          // Order is the identity of a JSON array element.
          // biome-ignore lint/suspicious/noArrayIndexKey: positional data
          key={index}
          value={item}
          projectId={projectId}
          label={<span className="text-fg-faint">{index}:</span>}
        />
      ))}
    </Container>
  );
}

function ObjectNode({
  fields,
  projectId,
  label,
}: {
  fields: { [key: string]: Json };
  projectId: string;
  label?: ReactNode;
}) {
  const special = specialNode(fields, projectId, label);
  if (special !== null) return special;
  const entries = Object.entries(fields);
  if (entries.length === 0) {
    return (
      <Inline label={label}>
        <span>{"{}"}</span>
      </Inline>
    );
  }
  return (
    <Container
      label={label}
      preview={`{ ${entries.length} field${entries.length === 1 ? "" : "s"} }`}
    >
      {entries.map(([key, child]) => (
        <Node key={key} value={child} projectId={projectId} label={fieldLabel(key)} />
      ))}
    </Container>
  );
}

/** An object / record field label, e.g. `radius:`. */
function fieldLabel(name: string): ReactNode {
  return <span className="text-fg-muted">{name}:</span>;
}

function specialNode(fields: { [key: string]: Json }, projectId: string, label?: ReactNode) {
  switch (wireKindOf((key) => key in fields)) {
    case "redacted":
      return (
        <Inline label={label}>
          <Badge tone="danger">
            <EyeOff className="size-3" /> redacted
          </Badge>
        </Inline>
      );
    case "data": {
      // A constructor is a labelled record: the tag is the header, its fields indent straight below —
      // so a chain of constructors nests down-left instead of stepping right by each tag's width.
      const constructorName = String(fields[CONSTRUCTOR_KEY]);
      const payload = fields[VALUE_KEY] ?? null;
      const tag = (
        <Badge tone="info">
          <Braces className="size-3" /> {constructorName}
        </Badge>
      );
      const record =
        typeof payload === "object" && payload !== null && !Array.isArray(payload) ? payload : null;
      const entries = record !== null ? Object.entries(record) : [];
      if (entries.length === 0) {
        // Nullary constructor (or an empty record): just the tag.
        return <Inline label={label}>{tag}</Inline>;
      }
      const header = (
        <span className="inline-flex items-center gap-2">
          {label}
          {tag}
        </span>
      );
      return (
        <Container
          label={header}
          preview={`{ ${entries.length} field${entries.length === 1 ? "" : "s"} }`}
        >
          {entries.map(([key, child]) => (
            <Node key={key} value={child} projectId={projectId} label={fieldLabel(key)} />
          ))}
        </Container>
      );
    }
    case "file":
      return (
        <Inline label={label}>
          <FileChip projectId={projectId} blobId={String(fields[FILE_KEY])} />
        </Inline>
      );
    case "agent":
      return (
        <Inline label={label}>
          <Badge tone="info">
            <FunctionSquare className="size-3" /> agent {String(fields[AGENT_KEY])}
          </Badge>
        </Inline>
      );
    case "closure":
      return (
        <Inline label={label}>
          <Badge tone="info">
            <FunctionSquare className="size-3" /> closure {String(fields[MODULE_KEY] ?? "")}#
            {String(fields[CLOSURE_KEY])}
          </Badge>
        </Inline>
      );
    default:
      return null;
  }
}

function FileChip({ projectId, blobId }: { projectId: string; blobId: string }) {
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
        file
      </Badge>
      <button
        type="button"
        title="Download"
        disabled={busy}
        onClick={() => void download()}
        className="p-1 text-fg-faint transition-colors hover:bg-sunken hover:text-fg disabled:opacity-50"
      >
        <Download className="size-3.5" />
      </button>
    </span>
  );
}
