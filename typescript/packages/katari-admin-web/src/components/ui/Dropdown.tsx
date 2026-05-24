import {
  cloneElement,
  isValidElement,
  useEffect,
  useRef,
  useState,
  type ReactElement,
  type ReactNode,
} from "react";
import { AnimatePresence, motion } from "framer-motion";
import { cn } from "@/lib/cn";

type DropdownProps = {
  trigger: ReactElement<{ onClick?: (e: React.MouseEvent) => void }>;
  children: (close: () => void) => ReactNode;
  align?: "start" | "end";
  className?: string;
};

/**
 * Lightweight dropdown: pass a trigger element + a render function that
 * receives a `close` callback. Click-outside / Escape / route change close
 * it; nothing fancier than that. Swap for Radix if we hit accessibility
 * gaps.
 */
export function Dropdown({ trigger, children, align = "start", className }: DropdownProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onClick(e: MouseEvent) {
      if (
        containerRef.current !== null &&
        !containerRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === "Escape") setOpen(false);
    }
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  if (!isValidElement(trigger)) {
    throw new Error("Dropdown: trigger must be a valid React element");
  }

  const triggerWithHandler = cloneElement(trigger, {
    onClick: (e: React.MouseEvent) => {
      trigger.props.onClick?.(e);
      setOpen((o) => !o);
    },
  });

  return (
    <div ref={containerRef} className="relative">
      {triggerWithHandler}
      <AnimatePresence>
        {open && (
          <motion.div
            initial={{ opacity: 0, y: -4, scale: 0.97 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: -4, scale: 0.97 }}
            transition={{ duration: 0.12, ease: "easeOut" }}
            className={cn(
              "absolute z-50 mt-2 min-w-56 overflow-hidden border border-border bg-background ",
              align === "end" ? "right-0" : "left-0",
              className,
            )}
          >
            {children(() => setOpen(false))}
          </motion.div>
        )}
      </AnimatePresence>
    </div>
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
    <button
      type="button"
      onClick={onSelect}
      className={cn(
        "flex w-full items-center gap-2 px-3 py-2 text-left text-sm transition-colors hover:cursor-pointer",
        active === true
          ? "bg-accent text-accent-foreground"
          : "text-foreground hover:bg-muted",
        className,
      )}
    >
      {children}
    </button>
  );
}

export function DropdownDivider() {
  return <div className="my-1 border-t border-border" />;
}

export function DropdownLabel({ children }: { children: ReactNode }) {
  return (
    <div className="px-3 pt-2 pb-1 text-[10px] uppercase tracking-wider text-subtle-foreground">
      {children}
    </div>
  );
}
