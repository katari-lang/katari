import type { ComponentProps } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { cn } from "../../lib/cn";

/**
 * Markdown renderer for project READMEs. Every element is styled inline with the console's theme
 * tokens rather than through `@tailwindcss/typography` (which isn't wired here) — so `prose` classes
 * silently do nothing; this component is what actually gives a README its heading sizes, list bullets,
 * spacing, and code/table framing.
 */
export function MarkdownContent({ source, className }: { source: string; className?: string }) {
  return (
    <div className={cn("text-sm leading-7 text-fg", className)}>
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components}>
        {source}
      </ReactMarkdown>
    </div>
  );
}

const components = {
  h1: (props: ComponentProps<"h1">) => (
    <h1 className="mt-8 text-2xl font-semibold tracking-tight first:mt-0" {...props} />
  ),
  h2: (props: ComponentProps<"h2">) => (
    <h2 className="mt-8 pb-1 text-xl font-semibold tracking-tight first:mt-0" {...props} />
  ),
  h3: (props: ComponentProps<"h3">) => (
    <h3 className="mt-6 text-base font-semibold tracking-tight first:mt-0" {...props} />
  ),
  h4: (props: ComponentProps<"h4">) => (
    <h4 className="mt-6 text-sm font-semibold tracking-tight first:mt-0" {...props} />
  ),
  p: (props: ComponentProps<"p">) => <p className="mt-4 leading-7 first:mt-0" {...props} />,
  a: ({ href, ...rest }: ComponentProps<"a">) => (
    <a
      href={href}
      target={href?.startsWith("http") === true ? "_blank" : undefined}
      rel={href?.startsWith("http") === true ? "noreferrer noopener" : undefined}
      className="font-medium text-fg underline underline-offset-4 hover:text-accent"
      {...rest}
    />
  ),
  ul: (props: ComponentProps<"ul">) => (
    <ul className="mt-4 ml-6 list-disc space-y-1.5 first:mt-0" {...props} />
  ),
  ol: (props: ComponentProps<"ol">) => (
    <ol className="mt-4 ml-6 list-decimal space-y-1.5 first:mt-0" {...props} />
  ),
  li: (props: ComponentProps<"li">) => <li className="leading-7" {...props} />,
  blockquote: (props: ComponentProps<"blockquote">) => (
    <blockquote
      className="mt-6 border-l border-edge-strong pl-4 italic text-fg-muted first:mt-0"
      {...props}
    />
  ),
  hr: (props: ComponentProps<"hr">) => <hr className="my-8 border-edge" {...props} />,
  table: (props: ComponentProps<"table">) => (
    <div className="my-6 overflow-x-auto">
      <table className="w-full text-sm" {...props} />
    </div>
  ),
  th: (props: ComponentProps<"th">) => (
    <th className="border border-edge bg-sunken px-3 py-2 text-left font-semibold" {...props} />
  ),
  td: (props: ComponentProps<"td">) => <td className="border border-edge px-3 py-2" {...props} />,
  pre: (props: ComponentProps<"pre">) => (
    <pre className="my-4 overflow-x-auto border border-edge bg-sunken/40 p-3 text-xs" {...props} />
  ),
  // Inline code only — fenced blocks arrive as `pre > code`; that nested `code` is intentionally left
  // unstyled so the `pre` box above owns the framing.
  code: ({ className, children, ...rest }: ComponentProps<"code">) => {
    const isBlock = typeof className === "string" && className.includes("language-");
    if (isBlock) {
      return (
        <code className={className} {...rest}>
          {children}
        </code>
      );
    }
    return (
      <code
        className="border border-edge bg-sunken/50 px-1.5 py-0.5 font-mono text-[13px]"
        {...rest}
      >
        {children}
      </code>
    );
  },
};
