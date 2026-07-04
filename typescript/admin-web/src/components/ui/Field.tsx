// Atomic form controls sharing one visual language. `fieldClass` is the single home of the
// bordered-control style so Input / TextArea / Select never drift apart.

import type { InputHTMLAttributes, SelectHTMLAttributes, TextareaHTMLAttributes } from "react";
import { cn } from "../../lib/cn";

const fieldClass =
  "w-full border border-edge-strong bg-raised px-2.5 py-1.5 text-sm text-fg placeholder:text-fg-faint focus:border-accent focus:outline-none disabled:opacity-50";

export function Input({ className, ...rest }: InputHTMLAttributes<HTMLInputElement>) {
  return <input className={cn(fieldClass, className)} {...rest} />;
}

export function TextArea({ className, ...rest }: TextareaHTMLAttributes<HTMLTextAreaElement>) {
  return <textarea className={cn(fieldClass, "min-h-20 font-mono text-xs", className)} {...rest} />;
}

export function Select({ className, children, ...rest }: SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <select className={cn(fieldClass, "appearance-none", className)} {...rest}>
      {children}
    </select>
  );
}

export function Label({
  text,
  children,
  hint,
}: {
  text: string;
  hint?: string;
  children?: React.ReactNode;
}) {
  // A fieldset rather than a <label>: the labelled child is often a composite (a whole schema
  // form), which a label element cannot legally be associated with.
  return (
    <fieldset aria-label={text} className="flex flex-col gap-1 text-sm">
      <span className="font-medium text-fg">
        {text}
        {hint !== undefined && <span className="pl-2 font-normal text-fg-faint">{hint}</span>}
      </span>
      {children}
    </fieldset>
  );
}

export function Switch({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      className="inline-flex items-center gap-2 text-sm text-fg"
    >
      <span
        className={cn(
          "inline-flex h-5 w-9 items-center rounded-full p-0.5 transition-colors",
          checked ? "bg-accent" : "bg-edge-strong",
        )}
      >
        <span
          className={cn(
            "size-4 rounded-full bg-raised transition-transform",
            checked && "translate-x-4",
          )}
        />
      </span>
      {label}
    </button>
  );
}
