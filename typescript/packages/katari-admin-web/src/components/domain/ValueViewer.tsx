import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

/**
 * JSON viewer that highlights redacted secret placeholders in the danger
 * tone. The wire layer replaces every `secret` Value with a string like
 * "<redacted:hash8>" — we surface those visually so the operator can see
 * "this field WAS sensitive" without revealing anything.
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
  const json = JSON.stringify(value, null, 2);
  return (
    <pre
      className={cn(
        "max-h-96 overflow-auto border border-border bg-muted p-3 text-xs leading-relaxed font-mono",
        className,
      )}
    >
      <code>{highlightRedacted(json)}</code>
    </pre>
  );
}

function highlightRedacted(json: string): ReactNode[] {
  const pattern = /"<redacted:[0-9a-f]{8}>"|"<redacted>"/g;
  const parts: ReactNode[] = [];
  let lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(json)) !== null) {
    if (match.index > lastIndex) {
      parts.push(json.slice(lastIndex, match.index));
    }
    parts.push(
      <span
        key={match.index}
        className="rounded bg-danger/15 px-1 text-danger"
        title="Value was redacted at the wire boundary because the original carried the secret type."
      >
        {match[0]}
      </span>,
    );
    lastIndex = match.index + match[0].length;
  }
  if (lastIndex < json.length) parts.push(json.slice(lastIndex));
  return parts;
}
