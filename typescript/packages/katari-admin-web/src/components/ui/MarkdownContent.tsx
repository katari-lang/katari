import type { ComponentProps } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "@/lib/cn";

type Props = {
  source: string;
  className?: string;
};

/**
 * Markdown renderer for project READMEs. Style choices mirror
 * katari-web's MDX components map so the visual feel is consistent
 * between docs site and admin dashboard. We keep everything inline (no
 * `@tailwindcss/typography` plugin) to stay in lock-step with that
 * styling and so theme-aware color tokens (`text-foreground`,
 * `border-border`, etc.) apply directly.
 */
export function MarkdownContent({ source, className }: Props) {
  return (
    <div className={cn("text-sm leading-7 text-foreground", className)}>
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components}>
        {source}
      </ReactMarkdown>
    </div>
  );
}

const components = {
  h1: (props: ComponentProps<"h1">) => (
    <h1
      className="mt-8 scroll-mt-24 text-3xl font-bold tracking-tight first:mt-0"
      {...props}
    />
  ),
  h2: (props: ComponentProps<"h2">) => (
    <h2
      className="mt-10 scroll-mt-24 pb-2 text-2xl font-semibold tracking-tight first:mt-0"
      {...props}
    />
  ),
  h3: (props: ComponentProps<"h3">) => (
    <h3
      className="mt-8 scroll-mt-24 text-xl font-semibold tracking-tight first:mt-0"
      {...props}
    />
  ),
  h4: (props: ComponentProps<"h4">) => (
    <h4
      className="mt-6 scroll-mt-24 text-lg font-semibold tracking-tight first:mt-0"
      {...props}
    />
  ),
  p: (props: ComponentProps<"p">) => (
    <p className="mt-4 leading-7" {...props} />
  ),
  a: ({ href, ...rest }: ComponentProps<"a">) => (
    <a
      href={href}
      target={href?.startsWith("http") === true ? "_blank" : undefined}
      rel={
        href?.startsWith("http") === true ? "noreferrer noopener" : undefined
      }
      className="font-medium text-foreground underline underline-offset-4 hover:text-highlight"
      {...rest}
    />
  ),
  ul: (props: ComponentProps<"ul">) => (
    <ul className="mt-4 ml-6 list-disc space-y-1.5" {...props} />
  ),
  ol: (props: ComponentProps<"ol">) => (
    <ol className="mt-4 ml-6 list-decimal space-y-1.5" {...props} />
  ),
  li: (props: ComponentProps<"li">) => <li className="leading-7" {...props} />,
  blockquote: (props: ComponentProps<"blockquote">) => (
    <blockquote
      className="mt-6 border-l border-border-strong pl-4 italic text-muted-foreground"
      {...props}
    />
  ),
  hr: (props: ComponentProps<"hr">) => (
    <hr className="my-8 border-border" {...props} />
  ),
  table: (props: ComponentProps<"table">) => (
    <div className="my-6 overflow-x-auto">
      <table className="w-full text-sm" {...props} />
    </div>
  ),
  th: (props: ComponentProps<"th">) => (
    <th
      className="border border-border bg-muted px-3 py-2 text-left font-semibold"
      {...props}
    />
  ),
  td: (props: ComponentProps<"td">) => (
    <td className="border border-border px-3 py-2" {...props} />
  ),
  pre: (props: ComponentProps<"pre">) => (
    <pre
      className="my-4 overflow-x-auto border border-border bg-muted/40 p-3 text-xs"
      {...props}
    />
  ),
  // Inline code only — fenced blocks come through `pre > code` and we
  // intentionally don't add wrapper styling to that nested `code` so
  // the `pre` styling above owns the box.
  code: ({ className, children, ...rest }: ComponentProps<"code">) => {
    const isBlock =
      typeof className === "string" && className.includes("language-");
    if (isBlock) {
      return (
        <code className={className} {...rest}>
          {children}
        </code>
      );
    }
    return (
      <code
        className="border border-border bg-muted/50 px-1.5 py-0.5 font-mono text-[13px]"
        {...rest}
      >
        {children}
      </code>
    );
  },
};
