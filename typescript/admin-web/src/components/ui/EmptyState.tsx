import type { LucideIcon } from "lucide-react";
import type { ReactNode } from "react";

export function EmptyState({
  icon: Icon,
  title,
  description,
  action,
}: {
  icon: LucideIcon;
  title: string;
  description?: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex flex-col items-center gap-2 p-10 text-center">
      <Icon className="size-8 text-fg-faint" />
      <p className="text-sm font-medium text-fg">{title}</p>
      {description !== undefined && <p className="max-w-sm text-sm text-fg-muted">{description}</p>}
      {action !== undefined && <div className="pt-2">{action}</div>}
    </div>
  );
}
