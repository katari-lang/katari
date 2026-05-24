import { SelectMenu } from "@/components/ui/SelectMenu";

export function EnumField({
  value,
  options,
  onChange,
}: {
  value: unknown;
  options: unknown[];
  onChange: (v: unknown) => void;
}) {
  const items = options.map((opt) => ({
    key: JSON.stringify(opt),
    label: typeof opt === "string" ? opt : JSON.stringify(opt),
  }));
  return (
    <div className="w-fit min-w-48">
      <SelectMenu
        value={JSON.stringify(value)}
        options={items}
        onChange={(key) => {
          try {
            onChange(JSON.parse(key));
          } catch {
            onChange(key);
          }
        }}
      />
    </div>
  );
}
