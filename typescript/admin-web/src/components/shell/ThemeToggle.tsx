import { Monitor, Moon, Sun } from "lucide-react";
import { cn } from "../../lib/cn";
import { type ThemePreference, useTheme } from "../../lib/theme";

const options: Array<{ value: ThemePreference; icon: typeof Sun; label: string }> = [
  { value: "light", icon: Sun, label: "Light" },
  { value: "system", icon: Monitor, label: "System" },
  { value: "dark", icon: Moon, label: "Dark" },
];

export function ThemeToggle() {
  const { preference, setPreference } = useTheme();
  return (
    <div className="flex items-center rounded-md border border-edge p-0.5">
      {options.map(({ value, icon: Icon, label }) => (
        <button
          key={value}
          type="button"
          title={label}
          aria-pressed={preference === value}
          onClick={() => setPreference(value)}
          className={cn(
            "rounded p-1.5 text-fg-faint transition-colors hover:text-fg",
            preference === value && "bg-sunken text-fg",
          )}
        >
          <Icon className="size-3.5" />
        </button>
      ))}
    </div>
  );
}
