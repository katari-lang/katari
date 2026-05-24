import { forwardRef, type ButtonHTMLAttributes } from "react";
import { cn } from "@/lib/cn";
import { Loader2 } from "lucide-react";

type Variant = "primary" | "secondary" | "ghost" | "danger";
type Size = "sm" | "md" | "lg";

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: Variant;
  size?: Size;
  loading?: boolean;
};

// `secondary` is the visual default for most buttons — border-only, hover
// promotes to muted bg. `primary` (filled accent) is reserved for ONE
// page-level "go" action (e.g. "Run agent", "Save"). `danger` keeps the
// fill since destructive intent needs a strong visual signal.
const variantClasses: Record<Variant, string> = {
  primary:
    "bg-highlight text-accent-foreground hover:bg-highlight/85 active:bg-highlight/75",
  secondary:
    "border border-border text-foreground hover:bg-muted hover:border-border-strong",
  ghost: "text-muted-foreground hover:bg-muted hover:text-foreground",
  danger:
    "bg-danger text-danger-foreground border border-danger hover:bg-danger/85 active:bg-danger/75",
};

const sizeClasses: Record<Size, string> = {
  sm: "h-8 px-3 text-xs gap-1.5",
  md: "h-9 px-4 text-sm gap-2",
  lg: "h-11 px-5 text-base gap-2",
};

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  function Button(
    {
      className,
      variant = "secondary",
      size = "md",
      loading,
      children,
      disabled,
      ...rest
    },
    ref,
  ) {
    return (
      <button
        ref={ref}
        disabled={(disabled ?? false) || loading === true}
        className={cn(
          "inline-flex items-center justify-center font-normal transition-colors",
          "hover:cursor-pointer disabled:cursor-not-allowed disabled:opacity-50",
          "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background",
          variantClasses[variant],
          sizeClasses[size],
          className,
        )}
        {...rest}
      >
        {loading === true ? <Loader2 className="size-4 animate-spin" /> : null}
        {children}
      </button>
    );
  },
);
