import { useEffect, useState } from "react";
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

  const [stored, setStored] = useState<ProjectId | null>(() => {
    if (typeof window === "undefined") return null;
    const value = window.localStorage.getItem(STORAGE_LAST_PROJECT);
    return value === null ? null : (value as ProjectId);
  });

  useEffect(() => {
    if (current === null) return;
    window.localStorage.setItem(STORAGE_LAST_PROJECT, current);
    setStored(current);
  }, [current]);

  return current ?? stored;
}
