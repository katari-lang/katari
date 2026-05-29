import { Plus, Trash2 } from "lucide-react";
import { useState } from "react";
import { Button } from "@/components/ui/Button";
import { Input } from "@/components/ui/Input";
import { SelectMenu } from "@/components/ui/SelectMenu";
import { BooleanField } from "./BooleanField";
import { NullField } from "./NullField";
import { NumberField } from "./NumberField";
import { StringField } from "./StringField";

type AnyKind = "string" | "number" | "boolean" | "null" | "data";

const ALL_KINDS: AnyKind[] = ["string", "number", "boolean", "null", "data"];

const KIND_LABELS: Record<AnyKind, string> = {
  string: "string",
  number: "number",
  boolean: "boolean",
  null: "null",
  data: "data (constructor)",
};

function detect(value: unknown): AnyKind {
  if (value === null) return "null";
  switch (typeof value) {
    case "string":
      return "string";
    case "number":
      return "number";
    case "boolean":
      return "boolean";
    case "object":
      return "data";
    default:
      return "data";
  }
}

function initial(kind: AnyKind): unknown {
  switch (kind) {
    case "string":
      return "";
    case "number":
      return 0;
    case "boolean":
      return false;
    case "null":
      return null;
    case "data":
      return { $constructor: "" };
  }
}

export function AnyField({ value, onChange }: { value: unknown; onChange: (v: unknown) => void }) {
  const [kind, setKind] = useState<AnyKind>(() => detect(value));

  function selectKind(next: AnyKind) {
    setKind(next);
    onChange(initial(next));
  }

  return (
    <div className="space-y-1.5">
      <div className="flex items-center gap-2">
        <span className="text-xs uppercase tracking-wider text-subtle-foreground">Type</span>
        <SelectMenu
          value={kind}
          onChange={(v) => selectKind(v as AnyKind)}
          options={ALL_KINDS.map((k) => ({ key: k, label: KIND_LABELS[k] }))}
          placeholder="Select type"
        />
      </div>
      {kind === "string" && <StringField value={value} onChange={onChange} />}
      {kind === "number" && <NumberField value={value} onChange={onChange} schema={{}} />}
      {kind === "boolean" && <BooleanField value={value} onChange={onChange} />}
      {kind === "null" && <NullField />}
      {kind === "data" && <DataField value={value} onChange={onChange} />}
    </div>
  );
}

function DataField({ value, onChange }: { value: unknown; onChange: (v: unknown) => void }) {
  const obj =
    value !== null && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : { $constructor: "" };

  const constructorName = typeof obj.$constructor === "string" ? obj.$constructor : "";

  const fields = Object.entries(obj).filter(([k]) => k !== "$constructor");

  const [nextId, setNextId] = useState(() => fields.length);

  function updateConstructor(name: string) {
    onChange({ ...obj, $constructor: name });
  }

  function addField() {
    const key = `field${nextId}`;
    setNextId((n) => n + 1);
    onChange({ ...obj, [key]: null });
  }

  function removeField(key: string) {
    const next = { ...obj };
    delete next[key];
    onChange(next);
  }

  function renameField(oldKey: string, newKey: string) {
    const entries = Object.entries(obj);
    const next: Record<string, unknown> = {};
    for (const [k, v] of entries) {
      next[k === oldKey ? newKey : k] = v;
    }
    onChange(next);
  }

  function changeFieldValue(key: string, v: unknown) {
    onChange({ ...obj, [key]: v });
  }

  return (
    <div className="space-y-2">
      <div className="space-y-1">
        <span className="text-xs text-muted-foreground">Constructor</span>
        <Input
          value={constructorName}
          onChange={(e) => updateConstructor(e.target.value)}
          placeholder="module.ConstructorName"
          className="h-8 text-xs font-mono"
        />
      </div>
      <div className="space-y-3 border-l border-border pl-3">
        {fields.length === 0 ? (
          <p className="text-xs italic text-subtle-foreground">No fields.</p>
        ) : (
          fields.map(([key, val]) => (
            <div key={key} className="space-y-1">
              <div className="flex items-center gap-2">
                <Input
                  value={key}
                  onChange={(e) => renameField(key, e.target.value)}
                  placeholder="field name"
                  className="h-7 flex-1 text-xs font-mono"
                />
                <button
                  type="button"
                  onClick={() => removeField(key)}
                  className="inline-flex h-7 w-7 shrink-0 items-center justify-center text-subtle-foreground transition-colors hover:bg-danger/10 hover:text-danger hover:cursor-pointer"
                  aria-label={`Remove field ${key}`}
                >
                  <Trash2 className="size-3.5" />
                </button>
              </div>
              <div className="pl-2">
                <AnyField value={val} onChange={(v) => changeFieldValue(key, v)} />
              </div>
            </div>
          ))
        )}
        <Button type="button" variant="secondary" size="sm" onClick={addField}>
          <Plus className="size-3.5" />
          Add field
        </Button>
      </div>
    </div>
  );
}
