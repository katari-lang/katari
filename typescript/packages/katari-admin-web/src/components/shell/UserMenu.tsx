import { useState, useRef, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { LogOut, User } from "lucide-react";
import { cn } from "@/lib/cn";
import { useApiKey } from "@/contexts/ApiKeyContext";

export function UserMenu() {
  const { apiKey, baseUrl, clear } = useApiKey();
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  useEffect(() => {
    if (!open) return;
    function onClick(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  if (apiKey === null) return null;

  const masked =
    apiKey.length <= 8
      ? "•".repeat(apiKey.length)
      : `${apiKey.slice(0, 4)}…${apiKey.slice(-4)}`;

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label="User menu"
        className="inline-flex h-9 w-9 items-center justify-center  text-muted-foreground transition-colors hover:bg-muted hover:text-foreground hover:cursor-pointer"
      >
        <User className="size-5" />
      </button>
      <div
        className={cn(
          "absolute right-0 mt-2 w-72  border border-border  ",
          "origin-top-right transition-all",
          open
            ? "scale-100 opacity-100"
            : "pointer-events-none scale-95 opacity-0",
        )}
      >
        <div className="border-b border-border p-3">
          <div className="text-xs uppercase tracking-wider text-subtle-foreground">
            Endpoint
          </div>
          <div className="mt-1 break-all font-mono text-xs text-foreground">
            {baseUrl}
          </div>
          <div className="mt-3 text-xs uppercase tracking-wider text-subtle-foreground">
            API key
          </div>
          <div className="mt-1 font-mono text-xs text-foreground">{masked}</div>
        </div>
        <button
          type="button"
          onClick={() => {
            clear();
            setOpen(false);
            navigate("/login");
          }}
          className="flex w-full items-center gap-2  px-3 py-2.5 text-sm text-foreground transition-colors hover:bg-muted hover:cursor-pointer"
        >
          <LogOut className="size-4" />
          Sign out
        </button>
      </div>
    </div>
  );
}
