import type { ComponentType, ReactNode, SVGProps } from "react";

type EmptyStateProps = {
  icon?: ComponentType<SVGProps<SVGSVGElement>>;
  title: string;
  description?: ReactNode;
  action?: ReactNode;
};

export function EmptyState({ icon: Icon, title, description, action }: EmptyStateProps) {
  return (
    <div className="flex flex-col items-center justify-center gap-3 py-12 text-center">
      {Icon !== undefined && <Icon className="size-10 text-subtle-foreground" />}
      <div>
        <h2 className="text-base font-semibold text-foreground">{title}</h2>
        {description !== undefined && (
          <p className="mt-1 text-sm text-muted-foreground">{description}</p>
        )}
      </div>
      {action !== undefined && <div>{action}</div>}
    </div>
  );
}
