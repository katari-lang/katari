import { Loader2 } from "lucide-react";
import { cn } from "../../lib/cn";

export function Spinner({ className }: { className?: string }) {
  return <Loader2 aria-label="Loading" className={cn("size-4 animate-spin", className)} />;
}

/** Centered loading state for a page / card body while its query is in flight. */
export function LoadingBlock() {
  return (
    <div className="flex items-center justify-center p-10 text-fg-faint">
      <Spinner className="size-5" />
    </div>
  );
}
