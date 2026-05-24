import { SchemaField } from "../SchemaField";
import type { JsonSchema } from "../schema-utils";

export function ObjectField({
  schema,
  value,
  onChange,
}: {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const obj = (value !== null && typeof value === "object" ? value : {}) as Record<
    string,
    unknown
  >;
  const properties = schema.properties ?? {};
  const required = new Set(schema.required ?? []);
  const entries = Object.entries(properties);

  if (entries.length === 0) {
    return (
      <p className=" border border-dashed border-border bg-muted/30 px-3 py-2 text-xs text-subtle-foreground">
        Empty object — nothing to fill in.
      </p>
    );
  }

  return (
    <div className="space-y-3  border border-border bg-muted/40 p-3">
      {entries.map(([key, sub]) => (
        <SchemaField
          key={key}
          name={key}
          schema={sub}
          value={obj[key]}
          required={required.has(key)}
          onChange={(v) => onChange({ ...obj, [key]: v })}
        />
      ))}
    </div>
  );
}
