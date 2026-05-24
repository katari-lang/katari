import { useEffect } from "react";
import type { ProjectId } from "@/api/types";
import { useCurrentProjectId } from "./useCurrentProjectId";

const STORAGE_LAST_PROJECT = "katari-admin.lastProjectId";

/**
 * Like {@link useCurrentProjectId}, but persists the last seen project to
 * localStorage and returns it when the current URL is outside any project
 * (= /env, /settings, /projects). This keeps the sidebar's "selected
 * project" indicator stable while operators navigate to runtime-global
 * pages, so they don't lose context.
 */
export function useStickyProjectId(): ProjectId | null {
  const current = useCurrentProjectId();

  useEffect(() => {
    if (current === null) return;
    window.localStorage.setItem(STORAGE_LAST_PROJECT, current);
  }, [current]);

  if (current !== null) return current;
  if (typeof window === "undefined") return null;
  const stored = window.localStorage.getItem(STORAGE_LAST_PROJECT);
  return stored === null ? null : (stored as ProjectId);
}
