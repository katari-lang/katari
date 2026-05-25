import { Check, Copy } from "lucide-react";
import { useState } from "react";
import toast from "react-hot-toast";
import { cn } from "@/lib/cn";

type Props = {
  /** Full id (uuid, qualified name, etc.) to copy. */
  value: string;
  /** What to render inline. Defaults to `value`. Pass a shortened form
   *  when the full id would wrap awkwardly. */
  display?: string;
  className?: string;
};

/**
 * Inline `<code> + copy button` for resource ids. Used on detail pages
 * for the page's own resource id (so operators can hand the id off to
 * the CLI without retyping). Related-resource ids are NOT shown — they
 * appear as human-readable names linked to their own detail pages,
 * where this widget surfaces the underlying id.
 *
 * The button shows a momentary check icon on success rather than only a
 * toast, so the click feels immediately acknowledged even if the toast
 * is missed.
 */
export function CopyableId({ value, display, className }: Props) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      toast.success("Copied");
      window.setTimeout(() => setCopied(false), 1200);
    } catch {
      toast.error("Copy failed");
    }
  }

  return (
    <span
      className={cn(
        "inline-flex items-center gap-1.5 font-mono text-xs",
        className,
      )}
    >
      <code className="break-all text-foreground">{display ?? value}</code>
      <button
        type="button"
        onClick={copy}
        aria-label="Copy ID"
        title={value}
        className="inline-flex shrink-0 items-center justify-center text-subtle-foreground transition-colors hover:text-foreground hover:cursor-pointer"
      >
        {copied ? (
          <Check className="size-3.5 text-success" />
        ) : (
          <Copy className="size-3.5" />
        )}
      </button>
    </span>
  );
}
