import { AnyField } from "./AnyField";

/**
 * Fallback for schemas we don't fully model (oneOf / anyOf / unknown
 * shapes). Delegates to AnyField which provides a type-selector UI
 * instead of raw JSON editing.
 */
export function UnknownField({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  return <AnyField value={value} onChange={onChange} />;
}
