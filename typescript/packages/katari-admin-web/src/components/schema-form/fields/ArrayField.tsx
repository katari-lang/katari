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
    <div className="space-y-2  border border-border bg-muted/40 p-3">
      {items.length === 0 ? (
        <p className="text-xs text-subtle-foreground">No items yet.</p>
      ) : (
        items.map((item, idx) => (
          <div
            key={idx}
            className="flex items-start gap-2  border border-border  p-2"
          >
            <span className="mt-2 inline-flex h-5 min-w-5 items-center justify-center rounded bg-muted px-1.5 font-mono text-[10px] text-muted-foreground">
              {idx}
            </span>
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
            <button
              type="button"
              onClick={() => {
                const next = items.slice();
                next.splice(idx, 1);
                onChange(next);
              }}
              className="mt-1 inline-flex h-7 w-7 items-center justify-center rounded text-subtle-foreground transition-colors hover:bg-danger/10 hover:text-danger hover:cursor-pointer"
              aria-label={`Remove item ${idx}`}
            >
              <Trash2 className="size-3.5" />
            </button>
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
