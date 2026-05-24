import { useCallback, useMemo, useState } from "react";
import { SchemaField } from "./SchemaField";
import { schemaInitialValue, type JsonSchema } from "./schema-utils";

type SchemaFormProps = {
  schema: JsonSchema;
  onSubmit: (value: Record<string, unknown>) => void;
  submitLabel?: string;
  renderActions?: (ctx: {
    submit: () => void;
    value: Record<string, unknown>;
  }) => React.ReactNode;
};

/**
 * Top-level form for a `parameters` schema (= an object schema). Manages
 * the form value in local state; calls `onSubmit` with the resulting
 * Record<string, unknown> when the operator clicks Run. Caller is free to
 * render its own submit button via `renderActions`.
 *
 * Schema is rendered verbatim — admin-web does not distinguish decl kinds
 * (agent / ext / data / req). The compiler emits a clean `parameters`
 * schema per the decl-agnostic Schema gen path, so no normalisation is
 * needed here.
 */
export function SchemaForm({
  schema,
  onSubmit,
  renderActions,
}: SchemaFormProps) {
  const initial = useMemo<Record<string, unknown>>(() => {
    const v = schemaInitialValue(schema);
    return (v !== null && typeof v === "object" ? v : {}) as Record<
      string,
      unknown
    >;
  }, [schema]);
  const [value, setValue] = useState<Record<string, unknown>>(initial);

  const submit = useCallback(() => {
    onSubmit(value);
  }, [onSubmit, value]);

  return (
    <form
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      className="space-y-4"
    >
      <SchemaField
        schema={schema}
        value={value}
        onChange={(v) => setValue(v as Record<string, unknown>)}
      />
      {renderActions !== undefined && renderActions({ submit, value })}
    </form>
  );
}
