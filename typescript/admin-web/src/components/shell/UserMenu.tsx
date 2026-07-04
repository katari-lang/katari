// The account menu in the top bar: which runtime this console is signed in to, and a log-out action.
// Logging out clears the stored key and re-arms the auth gate (via `reportUnauthorized`) so the login
// screen comes straight back — re-entering a key there is the only "change key" path we still need.

import { LogOut, User } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { setStoredApiToken } from "../../api/client";
import { reportUnauthorized } from "../../lib/auth";

export function UserMenu() {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  // The console talks to its runtime same-origin (`/api/v1`), so the origin is the runtime it serves.
  const runtimeUrl = window.location.origin;

  useEffect(() => {
    if (!open) return;
    const onPointerDown = (event: MouseEvent) => {
      if (
        containerRef.current !== null &&
        event.target instanceof Node &&
        !containerRef.current.contains(event.target)
      ) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", onPointerDown);
    return () => document.removeEventListener("mousedown", onPointerDown);
  }, [open]);

  const logout = () => {
    setStoredApiToken(null);
    reportUnauthorized();
  };

  return (
    <div ref={containerRef} className="relative">
      <button
        type="button"
        title="Account"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((previous) => !previous)}
        className="p-2 text-fg-muted transition-colors hover:bg-sunken hover:text-fg"
      >
        <User className="size-4" />
      </button>
      {open && (
        <div
          role="menu"
          className="absolute top-full right-0 z-40 mt-1 w-64 border border-edge bg-surface text-sm"
        >
          <div className="px-3 py-2">
            <p className="text-xs text-fg-faint">Signed in to</p>
            <p className="truncate font-mono text-xs text-fg" title={runtimeUrl}>
              {runtimeUrl}
            </p>
          </div>
          <button
            type="button"
            role="menuitem"
            onClick={logout}
            className="flex w-full items-center gap-2 px-3 py-2 text-left text-danger transition-colors hover:bg-sunken"
          >
            <LogOut className="size-3.5" /> Log out
          </button>
        </div>
      )}
    </div>
  );
}
