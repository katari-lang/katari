import { useQuery } from "@tanstack/react-query";
import { Bot, Download, FileText, Link2, Lock } from "lucide-react";
import { type ReactNode, useState } from "react";
import { Link } from "react-router-dom";
import type { RefModule } from "@/api/client";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { cn } from "@/lib/cn";
import { formatBytes } from "@/lib/format";

/**
 * Structured read-only viewer for JSON values. Renders a SchemaForm-like
 * tree with border-l indentation for nesting.
 *
 * Recognises Katari's reference shapes so they show as first-class refs,
 * not raw objects:
 *   - `{$agent: "qname@snapshot"}`     → an agent, linked to its page.
 *   - `{$agent: "closureref:<id>"}`    → a closure (ref chip, no link).
 *   - `{$ref: {module,id}, as:"file"}` → a file with a download link.
 *   - `{$ref: {module,id}, as:...}`    → any other ref (downloadable chip).
 * Redacted secret placeholders (`<redacted:hash8>`) are highlighted.
 */
export function ValueViewer({
  value,
  className,
  projectId,
}: {
  value: unknown;
  className?: string;
  /** Enables ref download links + agent page links. */
  projectId?: string;
}) {
  if (value === undefined) {
    return <span className="text-subtle-foreground italic">undefined</span>;
  }

  return (
    <div className={cn("relative", className)}>
      <ValueNode value={value} projectId={projectId} />
    </div>
  );
}

function ValueNode({ value, projectId }: { value: unknown; projectId?: string }) {
  if (value === null) {
    return <span className="text-xs font-mono italic text-subtle-foreground">null</span>;
  }

  if (typeof value === "boolean") {
    return (
      <span
        className={cn(
          "inline-flex items-center px-1.5 py-0.5 text-xs font-mono font-medium",
          value ? "bg-success/15 text-success" : "bg-danger/15 text-danger",
        )}
      >
        {String(value)}
      </span>
    );
  }

  if (typeof value === "number") {
    return <span className="text-xs font-mono text-highlight">{String(value)}</span>;
  }

  if (typeof value === "string") {
    return <StringValue text={value} />;
  }

  if (Array.isArray(value)) {
    if (value.length === 0) {
      return <span className="text-xs italic text-subtle-foreground">Empty array</span>;
    }
    return (
      <div className="flex flex-col space-y-2">
        <span className="text-xs font-mono font-medium text-muted-foreground">array</span>
        <div className="space-y-4 border-l border-border">
          {value.map((item, index) => (
            <div key={index} className="pl-3 flex flex-col gap-2 items-start">
              <span className="inline-flex items-center px-1.5 h-5 text-xs font-mono text-muted-foreground bg-muted">
                {index}
              </span>
              <ValueNode value={item} projectId={projectId} />
            </div>
          ))}
        </div>
      </div>
    );
  }

  if (typeof value === "object") {
    const record = value as Record<string, unknown>;

    // $secret: a redacted secret leaf.
    if ("$secret" in record) {
      return (
        <span
          className="inline-flex items-center gap-1 bg-danger/15 px-1.5 py-0.5 text-xs font-mono text-danger"
          title="This value carries the secret type."
        >
          <Lock className="size-3" />
          secret
        </span>
      );
    }

    // $agent: a callable reference (agent qname@snapshot, or closureref:<id>).
    if (typeof record.$agent === "string") {
      return <AgentValue agentId={record.$agent} projectId={projectId} />;
    }

    // $ref: a value reference (file / string / other). Downloadable.
    if (typeof record.$ref === "object" && record.$ref !== null) {
      return <RefValue record={record} projectId={projectId} />;
    }

    const entries = Object.entries(record);
    if (entries.length === 0) {
      return <span className="text-xs italic text-subtle-foreground">Empty object</span>;
    }

    // $constructor: a tagged-data value — show the ctor as the type label.
    const constructorName = typeof record.$constructor === "string" ? record.$constructor : null;
    const displayEntries =
      constructorName !== null ? entries.filter(([key]) => key !== "$constructor") : entries;

    return (
      <div className="flex flex-col space-y-2">
        <span className="text-xs font-mono font-medium text-muted-foreground">
          {constructorName ?? "record"}
        </span>
        <div className="border-l border-border pl-3 space-y-4">
          {displayEntries.map(([key, val]) => (
            <div key={key} className="flex flex-col gap-1">
              <span className="text-sm font-medium text-foreground">{key}</span>
              <ValueNode value={val} projectId={projectId} />
            </div>
          ))}
        </div>
      </div>
    );
  }

  // Fallback for unexpected types
  return <span className="text-xs font-mono text-foreground">{String(value)}</span>;
}

const CLOSURE_REF_PREFIX = "closureref:";

/** A callable value: an agent (linked to its page at the right snapshot) or a
 *  closure (a ref chip, no link — closures have no standalone page). */
function AgentValue({ agentId, projectId }: { agentId: string; projectId?: string }) {
  if (agentId.startsWith(CLOSURE_REF_PREFIX)) {
    const refId = agentId.slice(CLOSURE_REF_PREFIX.length);
    return (
      <RefChip icon={<Bot className="size-3" />} label="closure">
        <span className="text-foreground" title={refId}>
          {shortId(refId)}
        </span>
      </RefChip>
    );
  }

  // `qname@snapshot` (external form) or a bare qname (no snapshot).
  const at = agentId.indexOf("@");
  const qname = at >= 0 ? agentId.slice(0, at) : agentId;
  const snapshot = at >= 0 ? agentId.slice(at + 1) : undefined;
  const href =
    projectId !== undefined
      ? `/project/${projectId}/agents/${encodeURIComponent(qname)}${
          snapshot !== undefined ? `?snapshot=${snapshot}` : ""
        }`
      : null;

  return (
    <RefChip icon={<Bot className="size-3" />} label="agent">
      {href !== null ? (
        <Link to={href} className="text-foreground hover:underline" title={agentId}>
          {qname}
        </Link>
      ) : (
        <span className="text-foreground" title={agentId}>
          {qname}
        </span>
      )}
    </RefChip>
  );
}

/** A value reference. Files get a "file" label; anything else is a generic
 *  ref. All carry a download button (the data plane serves bytes by
 *  module + id, regardless of which module owns the blob). */
function RefValue({ record, projectId }: { record: Record<string, unknown>; projectId?: string }) {
  const ref = record.$ref as { module?: unknown; id?: unknown };
  const module = typeof ref.module === "string" ? (ref.module as RefModule) : undefined;
  const id = typeof ref.id === "string" ? ref.id : undefined;
  const as = typeof record.as === "string" ? record.as : undefined;
  const wireSize = typeof record.size === "number" ? record.size : undefined;
  const wireContentType = typeof record.contentType === "string" ? record.contentType : undefined;

  const label = as === "file" ? "file" : as === "string" ? "string (ref)" : "ref";
  const icon = as === "file" ? <FileText className="size-3" /> : <Link2 className="size-3" />;

  // The wire value carries only the ref handle (no display name, and no content
  // type for runtime-produced files) — fetch the authoritative ref metadata
  // (cheap, cached + deduped by react-query). Fall back to the wire fields.
  const client = useApiClient();
  const stateQ = useQuery({
    queryKey: ["value-state", projectId, module, id],
    queryFn: () => client.valueState(projectId as string, module as RefModule, id as string),
    enabled: as === "file" && projectId !== undefined && module !== undefined && id !== undefined,
    staleTime: 60_000,
  });
  const displayName = stateQ.data?.displayName;
  const contentType = stateQ.data?.contentType ?? wireContentType;
  const size = stateQ.data?.size ?? wireSize;

  return (
    <RefChip icon={icon} label={label}>
      <span className="text-foreground" title={module !== undefined ? `${module}/${id}` : id}>
        {displayName ?? (id !== undefined ? shortId(id) : "—")}
      </span>
      {size != null && (
        <span className="text-subtle-foreground">
          {formatBytes(size)}
          {contentType !== undefined ? ` · ${contentType}` : ""}
        </span>
      )}
      {projectId !== undefined && module !== undefined && id !== undefined && (
        <DownloadRefButton
          projectId={projectId}
          module={module}
          id={id}
          displayName={displayName}
          contentType={contentType}
        />
      )}
    </RefChip>
  );
}

/** Inline chip: a type label + a content slot, styled like the other
 *  monospace value pills. */
function RefChip({
  icon,
  label,
  children,
}: {
  icon: ReactNode;
  label: string;
  children: ReactNode;
}) {
  return (
    <span className="inline-flex flex-wrap items-center gap-2 border border-border bg-muted/40 px-2 py-1 text-xs font-mono">
      <span className="inline-flex items-center gap-1 text-muted-foreground">
        {icon}
        {label}
      </span>
      {children}
    </span>
  );
}

/** Downloads a ref's bytes via an authenticated fetch (the data plane requires
 *  the API key header, so a bare `<a href>` won't do). */
function DownloadRefButton({
  projectId,
  module,
  id,
  displayName,
  contentType,
}: {
  projectId: string;
  module: RefModule;
  id: string;
  displayName?: string;
  contentType?: string;
}) {
  const client = useApiClient();
  const [busy, setBusy] = useState(false);

  const download = async () => {
    setBusy(true);
    try {
      const blob = await client.valueBlob(projectId, module, id);
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = filenameFor(id, displayName, contentType);
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      URL.revokeObjectURL(url);
    } finally {
      setBusy(false);
    }
  };

  return (
    <button
      type="button"
      onClick={download}
      disabled={busy}
      className="inline-flex items-center gap-1 text-muted-foreground transition-colors hover:text-foreground hover:cursor-pointer disabled:opacity-50"
      title="Download"
    >
      <Download className="size-3" />
      {busy ? "…" : "download"}
    </button>
  );
}

function shortId(id: string): string {
  return id.length > 12 ? `${id.slice(0, 8)}…` : id;
}

/** The download filename. Prefer the ref's display name (a human name that
 *  already carries its extension, e.g. `notes.txt`) — content-type is declared,
 *  not detected, and often absent, so it's only a last-resort extension guess
 *  on top of the id. */
function filenameFor(id: string, displayName?: string, contentType?: string): string {
  if (displayName !== undefined && displayName !== "") return displayName;
  const ext =
    contentType !== undefined ? EXT_BY_TYPE[contentType.split(";")[0]!.trim()] : undefined;
  return ext !== undefined ? `${id}.${ext}` : id;
}

const EXT_BY_TYPE: Record<string, string> = {
  "text/plain": "txt",
  "application/json": "json",
  "text/csv": "csv",
  "text/markdown": "md",
  "text/html": "html",
  "application/pdf": "pdf",
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/svg+xml": "svg",
};

const REDACTED_PATTERN = /^<redacted:[0-9a-f]{8}>$|^<redacted>$/;

function StringValue({ text }: { text: string }) {
  if (REDACTED_PATTERN.test(text)) {
    return (
      <span
        className="bg-danger/15 px-1.5 py-0.5 text-xs font-mono text-danger"
        title="Value was redacted at the wire boundary because the original carried the secret type."
      >
        {`"${text}"`}
      </span>
    );
  }

  return (
    <span className="text-xs font-mono text-foreground">
      {highlightRedactedInline(`"${text}"`)}
    </span>
  );
}

/**
 * Highlight inline `<redacted:...>` substrings within longer strings.
 * This covers cases where the redacted placeholder appears embedded
 * inside a larger string value.
 */
function highlightRedactedInline(text: string): ReactNode[] {
  const pattern = /<redacted:[0-9a-f]{8}>|<redacted>/g;
  const parts: ReactNode[] = [];
  let lastIndex = 0;
  for (let match = pattern.exec(text); match !== null; match = pattern.exec(text)) {
    if (match.index > lastIndex) {
      parts.push(text.slice(lastIndex, match.index));
    }
    parts.push(
      <span
        key={match.index}
        className="bg-danger/15 px-1 text-danger"
        title="Value was redacted at the wire boundary because the original carried the secret type."
      >
        {match[0]}
      </span>,
    );
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < text.length) parts.push(text.slice(lastIndex));
  return parts;
}
