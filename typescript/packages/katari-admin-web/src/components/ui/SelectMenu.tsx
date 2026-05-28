import * as SelectPrimitive from "@radix-ui/react-select";
import { Check, ChevronDown } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export type SelectMenuOption = {
  /** Stable key for React + selected-state comparison. */
  key: string;
  /** Shown in both the trigger (when active) and the menu row. */
  label: ReactNode;
  /** Richer menu-row body; falls back to `label` when omitted. */
  detail?: ReactNode;
};

/**
 * Styled select menu built on Radix UI Select for proper accessibility
 * (keyboard navigation, ARIA). API is kept compatible with the previous
 * implementation.
 */
export function SelectMenu({
  value,
  options,
  onChange,
  placeholder,
}: {
  value: string;
  options: SelectMenuOption[];
  onChange: (key: string) => void;
  placeholder?: string;
}) {
  return (
    <SelectPrimitive.Root value={value} onValueChange={onChange}>
      <SelectPrimitive.Trigger className="inline-flex h-9 w-full items-center justify-between gap-2 border border-border bg-transparent px-3 text-sm text-foreground transition-colors hover:bg-muted hover:cursor-pointer hover:border-border-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
        <SelectPrimitive.Value placeholder={placeholder ?? "Select..."} />
        <SelectPrimitive.Icon>
          <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
        </SelectPrimitive.Icon>
      </SelectPrimitive.Trigger>
      <SelectPrimitive.Portal>
        <SelectPrimitive.Content
          position="popper"
          sideOffset={4}
          className={cn(
            "z-50 max-h-80 w-(--radix-select-trigger-width) overflow-hidden border border-border bg-background",
            "data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-[0.97]",
            "data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-[0.97]",
          )}
        >
          <SelectPrimitive.Viewport className="max-h-80 overflow-y-auto">
            {options.map((opt) => (
              <SelectPrimitive.Item
                key={opt.key}
                value={opt.key}
                className={cn(
                  "flex w-full items-center gap-2 px-3 py-2 text-left text-sm outline-none transition-colors hover:cursor-pointer",
                  opt.key === value
                    ? "bg-accent text-accent-foreground"
                    : "text-foreground data-highlighted:bg-muted",
                )}
              >
                <SelectPrimitive.ItemText>{opt.detail ?? opt.label}</SelectPrimitive.ItemText>
                {opt.key === value && (
                  <SelectPrimitive.ItemIndicator>
                    <Check className="size-4 shrink-0" />
                  </SelectPrimitive.ItemIndicator>
                )}
              </SelectPrimitive.Item>
            ))}
          </SelectPrimitive.Viewport>
        </SelectPrimitive.Content>
      </SelectPrimitive.Portal>
    </SelectPrimitive.Root>
  );
}
