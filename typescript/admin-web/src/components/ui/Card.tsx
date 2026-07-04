import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

export function Card({ className, children }: { className?: string; children: ReactNode }) {
  return <section className={cn("border border-edge bg-surface", className)}>{children}</section>;
}

/** Card header combo: title on the left, optional actions on the right. */
export function CardHeader({ title, actions }: { title: ReactNode; actions?: ReactNode }) {
  return (
    <header className="flex items-center justify-between gap-2 border-edge px-4 py-2.5">
      <h2 className="font-display-text text-sm font-semibold text-fg">{title}</h2>
      {actions}
    </header>
  );
}

export function CardBody({ className, children }: { className?: string; children: ReactNode }) {
  return <div className={cn("p-4", className)}>{children}</div>;
}
