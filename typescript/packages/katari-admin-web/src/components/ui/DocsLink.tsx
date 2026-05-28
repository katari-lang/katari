import { CircleHelp } from "lucide-react";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";
import { docsUrl } from "@/lib/docs";

type HelpLinkProps = {
  /** Docs slug (without version prefix), e.g. `"concepts/agents"`. */
  slug: string;
  /** Tooltip text shown on hover. Should describe where the link goes. */
  title?: string;
  className?: string;
};

/**
 * Circle-help icon that opens a docs page in a new tab. Sized to sit
 * neatly in PageHeader's actions slot.
 */
export function HelpLink({ slug, title, className }: HelpLinkProps) {
  return (
    <a
      href={docsUrl(slug)}
      target="_blank"
      rel="noreferrer noopener"
      aria-label={title ?? "Open documentation"}
      title={title ?? "Open documentation"}
      className={cn(
        "inline-flex items-center justify-center p-2 text-subtle-foreground transition-colors hover:text-foreground",
        className,
      )}
    >
      <CircleHelp className="size-3.5" />
    </a>
  );
}

type DocsLinkProps = {
  /** Docs slug (without version prefix). */
  slug: string;
  children: ReactNode;
  className?: string;
};

/**
 * Inline hyperlink to a docs page. Use this inside body copy when the
 * link target is a documentation page; for opening docs from a page
 * header, prefer `HelpLink`.
 */
export function DocsLink({ slug, children, className }: DocsLinkProps) {
  return (
    <a
      href={docsUrl(slug)}
      target="_blank"
      rel="noreferrer noopener"
      className={cn(
        "font-medium text-foreground underline underline-offset-4 hover:text-highlight",
        className,
      )}
    >
      {children}
    </a>
  );
}
