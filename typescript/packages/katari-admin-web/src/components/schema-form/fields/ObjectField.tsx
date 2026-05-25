import { useEffect } from "react";
import { SchemaField } from "../SchemaField";
import type { JsonSchema } from "../schema-utils";

/**
 * Object form: one field per `properties` entry. Const-typed properties
 * (e.g. `$constructor: {const: "main.Foo"}` emitted by katari for data ctors)
 * are auto-set and hidden from the UI — operators don't need to type
 * "main.Foo" themselves. The const value is still injected into the
 * outgoing object so the wire shape stays whole.
 */
export function ObjectField({
  schema,
  value,
  onChange,
}: {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const obj = (
    value !== null && typeof value === "object" ? value : {}
  ) as Record<string, unknown>;
  const properties = schema.properties ?? {};
  const required = new Set(schema.required ?? []);
  const entries = Object.entries(properties);

  // Auto-inject const values. If schemaInitialValue already set them on
  // first mount this is a no-op; needed when value comes from elsewhere
  // (e.g. a parent UnionField swapped branches without seeding).
  useEffect(() => {
    let patched = obj;
    let dirty = false;
    for (const [key, sub] of entries) {
      if (sub.const !== undefined && patched[key] !== sub.const) {
        patched = { ...patched, [key]: sub.const };
        dirty = true;
      }
    }
    if (dirty) onChange(patched);
    // Intentionally only run when the schema's const set changes; running
    // on every value change would fight user edits.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [schema]);

  // Hide const properties from the rendered form — they're auto-set.
  const visibleEntries = entries.filter(([, sub]) => sub.const === undefined);

  if (visibleEntries.length === 0) {
    return (
      <p className="border border-dashed border-border bg-muted/30 px-3 py-2 text-xs text-subtle-foreground">
        Nothing to fill in.
      </p>
    );
  }

  return (
    <div className="space-y-3 border-l border-border pl-3">
      {visibleEntries.map(([key, sub]) => (
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
