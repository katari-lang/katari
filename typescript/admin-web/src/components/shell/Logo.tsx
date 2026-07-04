import { cn } from "../../lib/cn";

/** The console lockup: the Katari glyph (a masked SVG that takes `currentColor`) + the "KATARI"
 * wordmark in the display face (Montserrat) + a small bordered "Console" tag. */
export function Logo({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-2 text-fg", className)}>
      <LogoMark className="h-6" />
      <span className="font-display text-base font-bold uppercase leading-none tracking-tight">
        Katari
      </span>
      <span className="border border-edge bg-sunken px-1.5 py-0.5 font-mono text-[10px] uppercase tracking-wider text-fg-muted">
        Console
      </span>
    </span>
  );
}

/** The glyph alone. Rendered as a masked block so it inherits the surrounding text color and works
 * unchanged in light / dark. */
export function LogoMark({ className }: { className?: string }) {
  return (
    <span
      aria-hidden
      className={cn("inline-block aspect-square bg-current", className)}
      style={{
        maskImage: "url(/katari.svg)",
        WebkitMaskImage: "url(/katari.svg)",
        maskRepeat: "no-repeat",
        WebkitMaskRepeat: "no-repeat",
        maskSize: "contain",
        WebkitMaskSize: "contain",
        maskPosition: "center",
        WebkitMaskPosition: "center",
      }}
    />
  );
}
