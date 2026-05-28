import type { ReactNode } from "react";
import { HelpLink } from "@/components/ui/DocsLink";
import { cn } from "@/lib/cn";

type PageHeaderProps = {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  /** Docs slug for the help icon. Renders next to the title and opens
   *  the doc in a new tab. Omit on pages with no dedicated doc. */
  docs?: { slug: string; title?: string };
  className?: string;
};

export function PageHeader({ title, description, actions, docs, className }: PageHeaderProps) {
  return (
    <header
      className={cn(
        "flex flex-col gap-1  px-6 pb-5 sm:flex-row sm:items-end sm:justify-between",
        className,
      )}
    >
      <div className="space-y-1">
        <div className="flex items-baseline gap-1">
          <h1 className="text-2xl font-semibold tracking-tight text-highlight font-display-text">
            {title}
          </h1>
          {docs !== undefined && <HelpLink slug={docs.slug} title={docs.title} />}
        </div>
        {description !== undefined && (
          <p className="text-sm text-muted-foreground">{description}</p>
        )}
      </div>
      {actions !== undefined && <div className="flex items-center gap-2">{actions}</div>}
    </header>
  );
}

export function PageContent({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn("p-6", className)}>{children}</div>;
}
