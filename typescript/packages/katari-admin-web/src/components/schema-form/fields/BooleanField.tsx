import { Switch } from "@/components/ui/Switch";

export function BooleanField({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const checked = value === true;
  return <Switch checked={checked} onChange={(v) => onChange(v)} />;
}
