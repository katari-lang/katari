import { cn } from "@/lib/cn";

export function EnumField({
  value,
  options,
  onChange,
}: {
  value: unknown;
  options: unknown[];
  onChange: (v: unknown) => void;
}) {
  return (
    <select
      value={JSON.stringify(value)}
      onChange={(e) => {
        try {
          onChange(JSON.parse(e.target.value));
        } catch {
          onChange(e.target.value);
        }
      }}
      className={cn(
        "h-9 w-full  border border-border-strong  px-3 text-sm text-foreground",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
      )}
    >
      {options.map((opt, idx) => (
        <option key={idx} value={JSON.stringify(opt)}>
          {typeof opt === "string" ? opt : JSON.stringify(opt)}
        </option>
      ))}
    </select>
  );
}
