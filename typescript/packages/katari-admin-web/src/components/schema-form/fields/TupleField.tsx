import { SchemaField } from "../SchemaField";
import type { JsonSchema } from "../schema-utils";

/**
 * Fixed-position array (= JSON Schema `prefixItems`). Each position has
 * its own schema; no add / remove. Renders as a row of indexed fields.
 */
export function TupleField({
  schema,
  value,
  onChange,
}: {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const items = Array.isArray(value) ? value : [];
  const positions = schema.prefixItems ?? [];

  if (positions.length === 0) {
    return (
      <p className="border border-dashed border-border bg-muted/30 px-3 py-2 text-xs text-subtle-foreground">
        Empty tuple — nothing to fill in.
      </p>
    );
  }

  return (
    <div className="space-y-2 border-l border-border p-3">
      {positions.map((sub, idx) => (
        <div key={idx} className="flex items-start gap-2">
          <span className="mt-2 inline-flex h-5 min-w-5 items-center justify-center px-1 font-mono text-xs">
            {idx}
          </span>
          <div className="flex-1">
            <SchemaField
              schema={sub}
              value={items[idx]}
              onChange={(v) => {
                const next = items.slice();
                while (next.length <= idx) next.push(null);
                next[idx] = v;
                onChange(next);
              }}
            />
          </div>
        </div>
      ))}
    </div>
  );
}
