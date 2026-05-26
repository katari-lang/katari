import { useEffect, useRef } from "react";
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

  // Keep a ref to the latest obj and onChange so the effect below can
  // read them without listing them as dependencies (which would cause
  // the effect to re-fire on every value change and fight user edits).
  const objRef = useRef(obj);
  objRef.current = obj;
  const onChangeRef = useRef(onChange);
  onChangeRef.current = onChange;

  // Auto-inject const values. If schemaInitialValue already set them on
  // first mount this is a no-op; needed when value comes from elsewhere
  // (e.g. a parent UnionField swapped branches without seeding).
  useEffect(() => {
    const currentObj = objRef.current;
    const constEntries = Object.entries(schema.properties ?? {});
    let patched = currentObj;
    let dirty = false;
    for (const [key, sub] of constEntries) {
      if (sub.const !== undefined && patched[key] !== sub.const) {
        patched = { ...patched, [key]: sub.const };
        dirty = true;
      }
    }
    if (dirty) onChangeRef.current(patched);
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
