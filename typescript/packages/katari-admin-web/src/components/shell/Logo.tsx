import { cn } from "@/lib/cn";

type LogoSize = "sm" | "md" | "lg";

const sizeVariants: Record<LogoSize, { height: string; text: string; badge: string }> = {
  sm: { height: "h-6", text: "text-sm", badge: "text-[10px]" },
  md: { height: "h-7", text: "text-base", badge: "text-[11px]" },
  lg: { height: "h-9", text: "text-lg", badge: "text-xs" },
};

type LogoProps = {
  className?: string;
  size?: LogoSize;
  showText?: boolean;
};

export function Logo({ className, size = "md", showText = true }: LogoProps) {
  const { height, text, badge } = sizeVariants[size];
  return (
    <span className={cn("inline-flex items-center gap-2", height, className)}>
      <LogoMark className="h-full" />
      {showText && (
        <span className={cn("font-display tracking-tight uppercase leading-none", text)}>
          Katari
        </span>
      )}
      <span
        className={cn(
          " border border-border bg-muted px-1.5 py-0.5 font-mono uppercase tracking-wider text-muted-foreground",
          badge,
        )}
      >
        Admin
      </span>
    </span>
  );
}

export function LogoMark({ className }: { className?: string }) {
  return (
    <span className={cn("inline-block", className)}>
      <span
        aria-hidden
        className="block h-full max-w-full aspect-square bg-current"
        style={{
          maskImage: "url(/admin/katari.svg)",
          WebkitMaskImage: "url(/admin/katari.svg)",
          maskRepeat: "no-repeat",
          WebkitMaskRepeat: "no-repeat",
          maskSize: "contain",
          WebkitMaskSize: "contain",
          maskPosition: "center",
          WebkitMaskPosition: "center",
        }}
      />
    </span>
  );
}
