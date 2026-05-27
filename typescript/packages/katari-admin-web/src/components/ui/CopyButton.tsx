import { Check, Copy } from "lucide-react";
import { useState } from "react";
import toast from "react-hot-toast";
import { cn } from "@/lib/cn";

type Props = {
  text: string;
  label?: string;
  children?: React.ReactNode;
  className?: string;
};

export function CopyButton({
  text,
  label = "Copied",
  children,
  className,
}: Props) {
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

  if (children !== undefined) {
    return (
      <button
        type="button"
        onClick={copy}
        className={cn(
          "inline-flex items-center gap-1.5 text-xs text-subtle-foreground transition-opacity hover:opacity-80 cursor-pointer",
          className,
        )}
      >
        {copied ? (
          <Check className="size-3.5 text-success" />
        ) : (
          <Copy className="size-3.5" />
        )}
        {children}
      </button>
    );
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
