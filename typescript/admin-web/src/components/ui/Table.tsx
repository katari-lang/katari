// Table combo: consistent paddings and hover/click affordances for every listing in the console.

import type { ReactNode } from "react";
import { cn } from "../../lib/cn";

export function Table({ headers, children }: { headers: ReactNode[]; children: ReactNode }) {
  return (
    <div className="overflow-x-auto">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-edge bg-sunken/50 text-left text-xs uppercase tracking-wider text-fg-faint">
            {headers.map((header, index) => (
              // Header cells are a fixed positional list; the index is a stable key here.
              // biome-ignore lint/suspicious/noArrayIndexKey: positional header row
              <th key={index} className="px-4 py-2 font-medium">
                {header}
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-edge">{children}</tbody>
      </table>
    </div>
  );
}

export function Row({ onClick, children }: { onClick?: () => void; children: ReactNode }) {
  const interactive = onClick !== undefined;
  return (
    <tr
      onClick={onClick}
      onKeyDown={
        interactive
          ? (event) => {
              if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                onClick();
              }
            }
          : undefined
      }
      tabIndex={interactive ? 0 : undefined}
      className={cn(interactive && "cursor-pointer transition-colors hover:bg-sunken")}
    >
      {children}
    </tr>
  );
}

export function Cell({ className, children }: { className?: string; children?: ReactNode }) {
  return <td className={cn("px-4 py-2.5 align-middle", className)}>{children}</td>;
}
