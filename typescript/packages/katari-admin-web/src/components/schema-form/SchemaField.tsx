import { Label } from "@/components/ui/Label";
import {
  isNeverSchema,
  singleType,
  unionBranches,
  type JsonSchema,
} from "./schema-utils";

const METADATA_KEYS = new Set(["description", "title", "default"]);

function isEmptySchema(schema: JsonSchema): boolean {
  return Object.keys(schema).every((k) => METADATA_KEYS.has(k));
}
import { StringField } from "./fields/StringField";
import { NumberField } from "./fields/NumberField";
import { BooleanField } from "./fields/BooleanField";
import { EnumField } from "./fields/EnumField";
import { NullField } from "./fields/NullField";
import { ObjectField } from "./fields/ObjectField";
import { ArrayField } from "./fields/ArrayField";
import { TupleField } from "./fields/TupleField";
import { UnionField } from "./fields/UnionField";
import { AnyField } from "./fields/AnyField";
import { UnknownField } from "./fields/UnknownField";

type SchemaFieldProps = {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
  name?: string;
  required?: boolean;
};

/**
 * Dispatch table from a JSON Schema fragment to a concrete UI field.
 * Falls back to UnknownField (= Monaco JSON editor) only for shapes we
 * genuinely can't form-render (= `never`, unrecognised keywords). All
 * common Katari emissions — primitives, enums, objects, arrays, tuples,
 * tagged-data ctors, anyOf/oneOf unions — go through real components.
 */
export function SchemaField({ schema, value, onChange, name, required }: SchemaFieldProps) {
  const label = schema.title ?? name;
  const inner = renderInner(schema, value, onChange);

  if (label === undefined && schema.description === undefined) {
    return inner;
  }

  return (
    <div className="space-y-1.5">
      {label !== undefined && (
        <div className="flex items-baseline gap-1.5">
          <Label>{label}</Label>
          {required === true && (
            <span className="text-xs uppercase tracking-wider text-danger">
              required
            </span>
          )}
        </div>
      )}
      {schema.description !== undefined && (
        <p className="text-xs text-subtle-foreground">{schema.description}</p>
      )}
      {inner}
    </div>
  );
}

function renderInner(
  schema: JsonSchema,
  value: unknown,
  onChange: (v: unknown) => void,
) {
  // `unknown` (= empty schema, or schema with only metadata keys like
  // `description` / `title`): no type constraint. Render the AnyField
  // type picker rather than dropping straight to a JSON editor.
  if (isEmptySchema(schema)) {
    return <AnyField value={value} onChange={onChange} />;
  }

  // `never`: no value can satisfy this shape. Render a clear indicator
  // rather than a JSON editor that pretends otherwise. Callers (e.g.
  // EscalationDetailPage) may special-case the surrounding UI to offer
  // a "cancel" action instead of accepting input.
  if (isNeverSchema(schema)) {
    return (
      <div className="border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning">
        This field's type is <code className="font-mono">never</code> — no
        value can satisfy it.
      </div>
    );
  }

  // Enum: dropdown. Beats free-text even when the type is e.g. string.
  if (Array.isArray(schema.enum) && schema.enum.length > 0) {
    return <EnumField value={value} options={schema.enum} onChange={onChange} />;
  }

  // Const: auto-set, no input. (ObjectField also strips const properties,
  // so this branch fires only when const is the entire schema — rare.)
  if (schema.const !== undefined) {
    return (
      <div className="border border-border bg-muted/40 px-3 py-2 text-xs">
        <span className="text-subtle-foreground">value:</span>{" "}
        <code className="font-mono text-foreground">{JSON.stringify(schema.const)}</code>
      </div>
    );
  }

  // Union (anyOf / oneOf): dropdown + selected branch's form.
  const branches = unionBranches(schema);
  if (branches !== null) {
    return <UnionField branches={branches} value={value} onChange={onChange} />;
  }

  const type = singleType(schema);
  switch (type) {
    case "string":
      return <StringField value={value} onChange={onChange} />;
    case "number":
    case "integer":
      return <NumberField value={value} onChange={onChange} schema={schema} />;
    case "boolean":
      return <BooleanField value={value} onChange={onChange} />;
    case "null":
      return <NullField />;
    case "object":
      return <ObjectField schema={schema} value={value} onChange={onChange} />;
    case "array":
      // Fixed-position tuple (= JSON Schema's `prefixItems`) vs
      // homogeneous list (= `items`). Katari emits tuples for
      // `(a, b, c)` source types.
      if (Array.isArray(schema.prefixItems)) {
        return <TupleField schema={schema} value={value} onChange={onChange} />;
      }
      return <ArrayField schema={schema} value={value} onChange={onChange} />;
    default:
      return <UnknownField value={value} onChange={onChange} />;
  }
}
