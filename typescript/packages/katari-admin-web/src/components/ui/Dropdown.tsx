import { useState } from "react";
import * as DropdownMenuPrimitive from "@radix-ui/react-dropdown-menu";
import type { ReactElement, ReactNode } from "react";
import { cn } from "@/lib/cn";

type DropdownProps = {
  trigger: ReactElement<{ onClick?: (e: React.MouseEvent) => void }>;
  children: (close: () => void) => ReactNode;
  align?: "start" | "end";
  className?: string;
};

/**
 * Dropdown built on Radix UI DropdownMenu for proper accessibility
 * (focus trap, ARIA, keyboard navigation). API is kept compatible
 * with the previous hand-rolled implementation.
 */
export function Dropdown({ trigger, children, align = "start", className }: DropdownProps) {
  const [open, setOpen] = useState(false);

  return (
    <DropdownMenuPrimitive.Root open={open} onOpenChange={setOpen}>
      <DropdownMenuPrimitive.Trigger asChild>
        {trigger}
      </DropdownMenuPrimitive.Trigger>
      <DropdownMenuPrimitive.Portal>
        <DropdownMenuPrimitive.Content
          align={align}
          sideOffset={8}
          className={cn(
            "z-50 min-w-56 overflow-hidden border border-border bg-background",
            "data-[state=open]:animate-in data-[state=open]:fade-in-0 data-[state=open]:zoom-in-[0.97]",
            "data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=closed]:zoom-out-[0.97]",
            className,
          )}
        >
          {children(() => setOpen(false))}
        </DropdownMenuPrimitive.Content>
      </DropdownMenuPrimitive.Portal>
    </DropdownMenuPrimitive.Root>
  );
}

export function DropdownItem({
  onSelect,
  active,
  className,
  children,
}: {
  onSelect?: () => void;
  active?: boolean;
  className?: string;
  children: ReactNode;
}) {
  return (
    <DropdownMenuPrimitive.Item
      onSelect={(e) => {
        e.preventDefault();
        onSelect?.();
      }}
      className={cn(
        "flex w-full items-center gap-2 px-3 py-2 text-left text-sm outline-none transition-colors hover:cursor-pointer",
        "data-[highlighted]:bg-muted",
        active === true
          ? "bg-accent text-accent-foreground"
          : "text-foreground",
        className,
      )}
    >
      {children}
    </DropdownMenuPrimitive.Item>
  );
}

export function DropdownDivider() {
  return <DropdownMenuPrimitive.Separator className="my-1 border-t border-border" />;
}

export function DropdownLabel({ children }: { children: ReactNode }) {
  return (
    <DropdownMenuPrimitive.Label className="px-3 pt-2 pb-1 text-xs uppercase tracking-wider text-subtle-foreground">
      {children}
    </DropdownMenuPrimitive.Label>
  );
}
