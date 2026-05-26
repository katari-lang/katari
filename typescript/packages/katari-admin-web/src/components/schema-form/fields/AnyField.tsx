import { useState } from "react";
import { cn } from "@/lib/cn";
import { JsonEditor } from "@/components/ui/JsonEditor";
import { StringField } from "./StringField";
import { NumberField } from "./NumberField";
import { BooleanField } from "./BooleanField";
import { NullField } from "./NullField";

type AnyKind = "string" | "number" | "boolean" | "null" | "json";

const ALL_KINDS: AnyKind[] = ["string", "number", "boolean", "null", "json"];

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
      return "json"; // arrays + plain objects both need JSON freeform input
    default:
      return "json";
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
    case "json":
      return {};
  }
}

/**
 * Form field for a schema that has no type constraint — i.e. the
 * compiler emitted `{}` (= `unknown` in Katari). We render a type
 * picker so primitive values get their natural input (text / numeric /
 * checkbox) and only nested / structural values fall back to a JSON
 * editor.
 *
 * Same UX pattern as UnionField (= dropdown + selected branch's form),
 * just with a synthetic 5-way branch list.
 */
export function AnyField({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const [kind, setKind] = useState<AnyKind>(() => detect(value));

  function selectKind(next: AnyKind) {
    setKind(next);
    onChange(initial(next));
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center gap-2">
        <span className="text-xs uppercase tracking-wider text-subtle-foreground">
          Type
        </span>
        <select
          value={kind}
          onChange={(e) => selectKind(e.target.value as AnyKind)}
          className={cn(
            "h-8 border border-border bg-transparent px-2 text-xs text-foreground transition-colors",
            "hover:border-border-strong focus-visible:outline-none focus-visible:border-ring",
          )}
        >
          {ALL_KINDS.map((k) => (
            <option key={k} value={k}>
              {k}
            </option>
          ))}
        </select>
      </div>
      {kind === "string" && <StringField value={value} onChange={onChange} />}
      {kind === "number" && (
        <NumberField value={value} onChange={onChange} schema={{}} />
      )}
      {kind === "boolean" && <BooleanField value={value} onChange={onChange} />}
      {kind === "null" && <NullField />}
      {kind === "json" && <AnyJsonEditor value={value} onChange={onChange} />}
    </div>
  );
}

/**
 * Inline JSON editor for the "json" branch — delegates to the shared
 * JsonEditor component with the `bg-card` variant.
 */
function AnyJsonEditor({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  return (
    <JsonEditor
      value={value}
      onChange={onChange}
      className="bg-card"
      fallback="{}"
    />
  );
}
