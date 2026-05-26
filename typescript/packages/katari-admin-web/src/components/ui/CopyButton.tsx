import { Check, Copy } from "lucide-react";
import { useState } from "react";
import toast from "react-hot-toast";
import { cn } from "@/lib/cn";

type Props = {
  /** The text to copy to the clipboard. */
  text: string;
  /** Label shown in the success toast. */
  label?: string;
  className?: string;
};

/**
 * Small icon-only clipboard button with momentary checkmark feedback.
 * Designed for embedding in card headers or alongside read-only values.
 */
export function CopyButton({ text, label = "Copied", className }: Props) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      toast.success(label);
      window.setTimeout(() => setCopied(false), 1200);
    } catch {
      toast.error("Copy failed");
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      aria-label="Copy to clipboard"
      className={cn(
        "inline-flex shrink-0 items-center justify-center text-subtle-foreground transition-colors hover:text-foreground hover:cursor-pointer",
        className,
      )}
    >
      {copied ? (
        <Check className="size-3.5 text-success" />
      ) : (
        <Copy className="size-3.5" />
      )}
    </button>
  );
}
