import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { SchemaField } from "../SchemaField";
import { schemaInitialValue, type JsonSchema } from "../schema-utils";

export function ArrayField({
  schema,
  value,
  onChange,
}: {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const items = Array.isArray(value) ? value : [];
  const itemSchema = schema.items ?? {};

  return (
    <div className="space-y-4 border-l border-border pl-3">
      {items.length === 0 ? (
        <p className="text-xs text-subtle-foreground">No items yet.</p>
      ) : (
        items.map((item, idx) => (
          <div key={idx} className="flex flex-col items-start gap-2">
            <div className="flex flex-row gap-2 items-center">
              <span className="inline-flex items-center justify-center font-mono text-xs px-1.5 h-5 bg-muted">
                {idx}
              </span>
              <button
                type="button"
                onClick={() => {
                  const next = items.slice();
                  next.splice(idx, 1);
                  onChange(next);
                }}
                className="inline-flex h-5 w-5 items-center justify-center rounded text-subtle-foreground transition-colors hover:text-danger hover:cursor-pointer"
                aria-label={`Remove item ${idx}`}
              >
                <Trash2 className="size-3.5" />
              </button>
            </div>
            <div className="flex-1">
              <SchemaField
                schema={itemSchema}
                value={item}
                onChange={(v) => {
                  const next = items.slice();
                  next[idx] = v;
                  onChange(next);
                }}
              />
            </div>
          </div>
        ))
      )}
      <Button
        type="button"
        variant="secondary"
        size="sm"
        onClick={() => onChange([...items, schemaInitialValue(itemSchema)])}
      >
        <Plus className="size-3.5" />
        Add item
      </Button>
    </div>
  );
}
