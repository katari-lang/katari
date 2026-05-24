import { Input } from "@/components/ui/Input";
import type { JsonSchema } from "../schema-utils";

export function NumberField({
  value,
  onChange,
  schema,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
  schema: JsonSchema;
}) {
  const isInteger = schema.type === "integer";
  return (
    <Input
      type="number"
      step={isInteger ? 1 : "any"}
      min={schema.minimum}
      max={schema.maximum}
      value={typeof value === "number" || typeof value === "string" ? value : ""}
      onChange={(e) => {
        const raw = e.target.value;
        if (raw === "") {
          onChange(0);
          return;
        }
        const n = isInteger ? Number.parseInt(raw, 10) : Number.parseFloat(raw);
        if (Number.isNaN(n)) return;
        onChange(n);
      }}
    />
  );
}
