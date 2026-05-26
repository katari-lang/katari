import { JsonEditor } from "@/components/ui/JsonEditor";

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
  return (
    <JsonEditor
      value={value}
      onChange={onChange}
      className="border-border-strong"
    />
  );
}
