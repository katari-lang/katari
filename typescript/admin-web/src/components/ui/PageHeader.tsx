import type { ReactNode } from "react";

/** Page title combo: heading + optional description on the left, actions on the right. */
export function PageHeader({
  title,
  description,
  actions,
}: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <header className="flex flex-wrap items-start justify-between gap-3 pb-5">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold text-fg">{title}</h1>
        {description !== undefined && <div className="text-sm text-fg-muted">{description}</div>}
      </div>
      {actions !== undefined && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  );
}
