import { Check, Copy } from "lucide-react";
import { useState } from "react";
import { shortId } from "../../lib/format";

export function CopyButton({ value, label }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      title={label ?? "Copy"}
      onClick={() => {
        void navigator.clipboard.writeText(value);
        setCopied(true);
        setTimeout(() => setCopied(false), 1200);
      }}
      className="p-1 text-fg-faint transition-colors hover:text-fg"
    >
      {copied ? <Check className="size-3.5 text-success" /> : <Copy className="size-3.5" />}
    </button>
  );
}

/** Truncated id + copy combo, for table cells and metadata rows. */
export function CopyableId({ id }: { id: string }) {
  return (
    <span className="inline-flex items-center gap-1 font-mono text-xs text-fg-muted" title={id}>
      {shortId(id)}
      <CopyButton value={id} label="Copy full id" />
    </span>
  );
}
