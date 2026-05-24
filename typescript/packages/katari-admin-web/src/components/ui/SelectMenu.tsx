import { Check, ChevronDown } from "lucide-react";
import type { ReactNode } from "react";
import { Dropdown, DropdownItem } from "./Dropdown";

export type SelectMenuOption = {
  /** Stable key for React + selected-state comparison. */
  key: string;
  /** Shown in both the trigger (when active) and the menu row. */
  label: ReactNode;
  /** Richer menu-row body; falls back to `label` when omitted. */
  detail?: ReactNode;
};

/**
 * Styled drop-down for picking one value from a small/medium option list.
 * Wraps `Dropdown` + `DropdownItem` so callers don't have to wire the
 * trigger button styling each time.
 */
export function SelectMenu({
  value,
  options,
  onChange,
  placeholder,
}: {
  value: string;
  options: SelectMenuOption[];
  onChange: (key: string) => void;
  placeholder?: string;
}) {
  const selected = options.find((o) => o.key === value);
  const trigger = (
    <button
      type="button"
      className="inline-flex h-9 w-full items-center justify-between gap-2 border border-border bg-transparent px-3 text-sm text-foreground transition-colors hover:bg-muted hover:cursor-pointer hover:border-border-strong focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
    >
      <span className="truncate">
        {selected !== undefined ? selected.label : (placeholder ?? "Select…")}
      </span>
      <ChevronDown className="size-4 shrink-0 text-muted-foreground" />
    </button>
  );
  return (
    <Dropdown trigger={trigger} className="w-full">
      {(close) => (
        <div className="max-h-80 overflow-y-auto">
          {options.map((opt) => (
            <DropdownItem
              key={opt.key}
              active={opt.key === value}
              onSelect={() => {
                close();
                onChange(opt.key);
              }}
            >
              <div className="flex-1 truncate">{opt.detail ?? opt.label}</div>
              {opt.key === value && <Check className="size-4 shrink-0" />}
            </DropdownItem>
          ))}
        </div>
      )}
    </Dropdown>
  );
}
