import { twMerge } from "tailwind-merge";

/** Compose class names, dropping falsy parts and resolving Tailwind conflicts (caller wins). */
export function cn(...parts: Array<string | false | null | undefined>): string {
  return twMerge(parts.filter(Boolean).join(" "));
}
