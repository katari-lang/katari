import Editor from "@monaco-editor/react";
import { useTheme } from "next-themes";
import { useState } from "react";

/**
 * Fallback for schemas we don't fully model (oneOf / anyOf / unknown
 * shapes). Operator types raw JSON; we parse on every keystroke and
 * surface parse errors inline.
 */
export function UnknownField({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const { resolvedTheme } = useTheme();
  const [text, setText] = useState(() => safeStringify(value));
  const [error, setError] = useState<string | null>(null);

  return (
    <div className="space-y-1">
      <div className="overflow-hidden  border border-border-strong ">
        <Editor
          height="160px"
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
      {error !== null && (
        <p className="text-xs text-danger">{error}</p>
      )}
    </div>
  );
}

function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v, null, 2);
  } catch {
    return "null";
  }
}
