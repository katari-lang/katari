import type { ReactNode } from "react";
import { Link } from "react-router-dom";
import { Lock } from "lucide-react";
import { cn } from "@/lib/cn";

/**
 * Structured read-only viewer for JSON values. Renders a SchemaForm-like
 * tree with border-l-2 indentation for nesting. Redacted secret
 * placeholders (`<redacted:hash8>`) are highlighted in the danger tone.
 */
export function ValueViewer({
  value,
  className,
  projectId,
}: {
  value: unknown;
  className?: string;
  /** When provided, $callable qualified names become links to the agent page. */
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

function ValueNode({
  value,
  projectId,
}: {
  value: unknown;
  projectId?: string;
}) {
  if (value === null) {
    return <span className="text-xs font-mono italic text-subtle-foreground">null</span>;
  }

  if (typeof value === "boolean") {
    return (
      <span
        className={cn(
          "inline-flex items-center px-1.5 py-0.5 text-xs font-mono font-medium",
          value
            ? "bg-success/15 text-success"
            : "bg-danger/15 text-danger",
        )}
      >
        {String(value)}
      </span>
    );
  }

  if (typeof value === "number") {
    return (
      <span className="text-xs font-mono text-highlight">
        {String(value)}
      </span>
    );
  }

  if (typeof value === "string") {
    return <StringValue text={value} />;
  }

  if (Array.isArray(value)) {
    if (value.length === 0) {
      return (
        <span className="text-xs italic text-subtle-foreground">Empty array</span>
      );
    }
    return (
      <div className="space-y-2">
        {value.map((item, index) => (
          <div key={index} className="border-l-2 border-border pl-3">
            <span className="inline-flex items-center px-1.5 py-0.5 text-xs font-mono text-muted-foreground bg-muted mb-1">
              {index}
            </span>
            <div className="mt-1">
              <ValueNode value={item} projectId={projectId} />
            </div>
          </div>
        ))}
      </div>
    );
  }

  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    const entries = Object.entries(record);

    if (entries.length === 0) {
      return (
        <span className="text-xs italic text-subtle-foreground">Empty object</span>
      );
    }

    // $secret handling: show a lock badge in danger color
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

    // $constructor handling: show constructor name as type label,
    // filter $constructor from properties list
    const constructorName =
      typeof record.$constructor === "string" ? record.$constructor : null;
    const displayEntries = constructorName !== null
      ? entries.filter(([key]) => key !== "$constructor")
      : entries;

    // $callable handling: render as link if it looks like a qualified name
    const callableName =
      typeof record.$callable === "string" ? record.$callable : null;

    return (
      <div className="space-y-2">
        {constructorName !== null && (
          <span className="text-xs font-mono font-medium text-muted-foreground">
            {constructorName}
          </span>
        )}
        {callableName !== null && (
          <div className="border-l-2 border-border pl-3">
            <span className="text-sm font-medium text-foreground">$callable</span>
            <div className="mt-1">
              {callableName.includes(".") && projectId !== undefined ? (
                <Link
                  to={`/project/${projectId}/agents/${encodeURIComponent(callableName)}`}
                  className="text-xs font-mono text-foreground hover:underline"
                >
                  {callableName}
                </Link>
              ) : (
                <span className="text-xs font-mono text-foreground">{callableName}</span>
              )}
            </div>
          </div>
        )}
        {displayEntries
          .filter(([key]) => key !== "$callable")
          .map(([key, val]) => (
            <div key={key} className="border-l-2 border-border pl-3">
              <span className="text-sm font-medium text-foreground">{key}</span>
              <div className="mt-1">
                <ValueNode value={val} projectId={projectId} />
              </div>
            </div>
          ))}
      </div>
    );
  }

  // Fallback for unexpected types
  return (
    <span className="text-xs font-mono text-foreground">
      {String(value)}
    </span>
  );
}

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
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(text)) !== null) {
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
