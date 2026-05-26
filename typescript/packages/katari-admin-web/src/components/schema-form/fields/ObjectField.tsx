import { useEffect, useRef, useState } from "react";
import { Plus, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { SchemaField } from "../SchemaField";
import { AnyField } from "./AnyField";
import type { JsonSchema } from "../schema-utils";

/**
 * Object form: one field per `properties` entry. Const-typed properties
 * (e.g. `$constructor: {const: "main.Foo"}` emitted by katari for data ctors)
 * are auto-set and hidden from the UI — operators don't need to type
 * "main.Foo" themselves. The const value is still injected into the
 * outgoing object so the wire shape stays whole.
 *
 * When `properties` is empty and `additionalProperties` is truthy the
 * schema represents Katari's `record` type — a dynamic string-keyed
 * map. In that case we render a key-value editor instead of the static
 * property list.
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

  // Dynamic key-value editor for `record` type: empty `properties` with
  // `additionalProperties` enabled.
  const hasAdditional = schema.additionalProperties !== undefined && schema.additionalProperties !== false;
  if (visibleEntries.length === 0 && hasAdditional) {
    return (
      <DynamicKeyValueEditor
        schema={schema}
        value={obj}
        onChange={onChange}
      />
    );
  }

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

// ── Dynamic key-value editor (record type) ─────────────────────────────

/**
 * Renders a mutable list of key-value pairs for schemas where the
 * object shape is entirely dynamic (`additionalProperties: true` or
 * `additionalProperties: <schema>`).
 */
function DynamicKeyValueEditor({
  schema,
  value,
  onChange,
}: {
  schema: JsonSchema;
  value: Record<string, unknown>;
  onChange: (v: unknown) => void;
}) {
  // Resolve the value schema: `true` → unconstrained (AnyField),
  // object → use it as JsonSchema for each value.
  const additionalProps = schema.additionalProperties;
  const valueSchema: JsonSchema | true =
    typeof additionalProps === "object" && additionalProps !== null
      ? (additionalProps as JsonSchema)
      : true;

  // Track insertion order so React keys stay stable across renames.
  // Each entry gets a monotonic id that never changes even when the
  // key is edited.
  const [rows, setRows] = useState<{ id: number; key: string }[]>(() =>
    Object.keys(value).map((key, idx) => ({ id: idx, key })),
  );
  const nextId = useRef(Object.keys(value).length);

  function addRow() {
    const id = nextId.current++;
    const newKey = "";
    const updated = [...rows, { id, key: newKey }];
    setRows(updated);
    onChange({ ...value, [newKey]: null });
  }

  function removeRow(id: number) {
    const row = rows.find((r) => r.id === id);
    if (row === undefined) return;
    const updated = rows.filter((r) => r.id !== id);
    setRows(updated);
    const next = { ...value };
    delete next[row.key];
    onChange(next);
  }

  function renameKey(id: number, newKey: string) {
    const row = rows.find((r) => r.id === id);
    if (row === undefined) return;
    const oldKey = row.key;
    setRows(rows.map((r) => (r.id === id ? { ...r, key: newKey } : r)));
    const next: Record<string, unknown> = {};
    for (const r of rows) {
      const k = r.id === id ? newKey : r.key;
      next[k] = value[r.id === id ? oldKey : r.key];
    }
    onChange(next);
  }

  function changeValue(key: string, v: unknown) {
    onChange({ ...value, [key]: v });
  }

  return (
    <div className="space-y-2 border border-border bg-muted/40 p-3">
      {rows.length === 0 ? (
        <p className="text-xs text-subtle-foreground">No entries yet.</p>
      ) : (
        rows.map((row) => (
          <div
            key={row.id}
            className="flex items-start gap-2 border border-border p-2"
          >
            <div className="w-36 shrink-0">
              <Input
                value={row.key}
                onChange={(e) => renameKey(row.id, e.target.value)}
                placeholder="key"
                className="h-8 text-xs font-mono"
              />
            </div>
            <div className="flex-1">
              {valueSchema === true ? (
                <AnyField
                  value={value[row.key]}
                  onChange={(v) => changeValue(row.key, v)}
                />
              ) : (
                <SchemaField
                  schema={valueSchema}
                  value={value[row.key]}
                  onChange={(v) => changeValue(row.key, v)}
                />
              )}
            </div>
            <button
              type="button"
              onClick={() => removeRow(row.id)}
              className="mt-1 inline-flex h-7 w-7 items-center justify-center text-subtle-foreground transition-colors hover:bg-danger/10 hover:text-danger hover:cursor-pointer"
              aria-label={`Remove entry ${row.key}`}
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
        onClick={addRow}
      >
        <Plus className="size-3.5" />
        Add field
      </Button>
    </div>
  );
}
