import type { ReactNode } from "react";

/** Definition-list combo for metadata cards: aligned label/value rows. */
export function KeyValueList({ children }: { children: ReactNode }) {
  return <dl className="flex flex-col gap-2 text-sm">{children}</dl>;
}

export function KeyValueRow({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-4">
      <dt className="shrink-0 text-fg-faint">{label}</dt>
      <dd className="min-w-0 text-right text-fg break-words">{children}</dd>
    </div>
  );
}
