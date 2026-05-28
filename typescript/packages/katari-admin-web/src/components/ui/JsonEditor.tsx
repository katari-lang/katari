import Editor from "@monaco-editor/react";
import { useTheme } from "next-themes";
import { useState } from "react";
import { cn } from "@/lib/cn";

/**
 * Textarea-style JSON editor backed by Monaco. Parses on every
 * keystroke and surfaces parse errors inline.
 */
export function JsonEditor({
  value,
  onChange,
  height = "160px",
  className,
  fallback = "null",
}: {
  value: unknown;
  onChange: (v: unknown) => void;
  /** CSS height string passed to Monaco. */
  height?: string;
  /** Extra class(es) on the outer wrapper `<div>`. */
  className?: string;
  /** Return value of `JSON.stringify` when it throws. */
  fallback?: string;
}) {
  const { resolvedTheme } = useTheme();
  const [text, setText] = useState(() => safeStringify(value, fallback));
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="space-y-1">
      <div className={cn("overflow-hidden border border-border", className)}>
        <Editor
          height={height}
          defaultLanguage="json"
          theme={resolvedTheme === "dark" ? "vs-dark" : "light"}
          value={text}
          options={{
            minimap: { enabled: false },
            fontSize: 13,
            lineNumbers: "off",
            scrollBeyondLastLine: false,
            wordWrap: "on",
          }}
          onChange={(next) => {
            const t = next ?? "";
            setText(t);
            try {
              onChange(t.trim() === "" ? null : JSON.parse(t));
              setError(null);
            } catch (e) {
              setError(e instanceof Error ? e.message : "Invalid JSON");
            }
          }}
        />
      </div>
      {error !== null && <p className="text-xs text-danger">{error}</p>}
    </div>
  );
}

function safeStringify(v: unknown, fallback: string): string {
  try {
    return JSON.stringify(v, null, 2);
  } catch {
    return fallback;
  }
}
