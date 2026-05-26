import { useCallback, useMemo, useState } from "react";
import { SchemaField } from "./SchemaField";
import { schemaInitialValue, type JsonSchema } from "./schema-utils";

type SchemaFormProps = {
  schema: JsonSchema;
  onSubmit: (value: unknown) => void;
  submitLabel?: string;
  renderActions?: (ctx: {
    submit: () => void;
    value: unknown;
  }) => React.ReactNode;
};

/**
 * Top-level form for any schema shape. Manages the form value in local
 * state; calls `onSubmit` with whatever value the inner fields produced
 * when the operator clicks Run. Caller is free to render its own submit
 * button via `renderActions`.
 *
 * Schema is rendered verbatim — admin-web does not distinguish decl kinds
 * (agent / ext / data / req) and does not assume the root is an object
 * schema (escalation answers are typed by the request's return type,
 * which is often a primitive).
 */
export function SchemaForm({
  schema,
  onSubmit,
  renderActions,
}: SchemaFormProps) {
  const initial = useMemo<unknown>(() => schemaInitialValue(schema), [schema]);
  const [value, setValue] = useState<unknown>(initial);

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
      <SchemaField schema={schema} value={value} onChange={setValue} />
      {renderActions !== undefined && renderActions({ submit, value })}
    </form>
  );
}
