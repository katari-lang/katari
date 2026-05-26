import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { CopyButton } from "@/components/ui/CopyButton";

/**
 * Structured read-only viewer for JSON values. Renders a SchemaForm-like
 * tree with border-l-2 indentation for nesting. Redacted secret
 * placeholders (`<redacted:hash8>`) are highlighted in the danger tone.
 */
export function ValueViewer({
  value,
  className,
}: {
  value: unknown;
  className?: string;
}) {
  if (value === undefined) {
    return <span className="text-subtle-foreground italic">undefined</span>;
  }

  return (
    <div className={cn("relative", className)}>
      <div className="absolute top-0 right-0">
        <CopyButton
          text={JSON.stringify(value, null, 2)}
          label="Copied JSON"
        />
      </div>
      <ValueNode value={value} />
    </div>
  );
}

function ValueNode({ value }: { value: unknown }) {
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
        <span className="text-xs font-mono text-subtle-foreground">[]</span>
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
              <ValueNode value={item} />
            </div>
          </div>
        ))}
      </div>
    );
  }

  if (typeof value === "object") {
    const entries = Object.entries(value as Record<string, unknown>);
    if (entries.length === 0) {
      return (
        <span className="text-xs font-mono text-subtle-foreground">{"{}"}</span>
      );
    }
    return (
      <div className="space-y-2">
        {entries.map(([key, val]) => (
          <div key={key} className="border-l-2 border-border pl-3">
            <span className="text-sm font-medium text-foreground">{key}</span>
            <div className="mt-1">
              <ValueNode value={val} />
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
