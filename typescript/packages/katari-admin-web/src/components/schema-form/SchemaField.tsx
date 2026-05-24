import { Label } from "@/components/ui/Label";
import { isUnion, singleType, type JsonSchema } from "./schema-utils";
import { StringField } from "./fields/StringField";
import { NumberField } from "./fields/NumberField";
import { BooleanField } from "./fields/BooleanField";
import { EnumField } from "./fields/EnumField";
import { NullField } from "./fields/NullField";
import { ObjectField } from "./fields/ObjectField";
import { ArrayField } from "./fields/ArrayField";
import { UnknownField } from "./fields/UnknownField";

type SchemaFieldProps = {
  schema: JsonSchema;
  value: unknown;
  onChange: (v: unknown) => void;
  name?: string;
  required?: boolean;
};

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
            <span className="text-[10px] uppercase tracking-wider text-danger">
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
  if (Array.isArray(schema.enum) && schema.enum.length > 0) {
    return <EnumField value={value} options={schema.enum} onChange={onChange} />;
  }
  if (isUnion(schema)) {
    return <UnknownField value={value} onChange={onChange} />;
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
      return <ArrayField schema={schema} value={value} onChange={onChange} />;
    default:
      return <UnknownField value={value} onChange={onChange} />;
  }
}
