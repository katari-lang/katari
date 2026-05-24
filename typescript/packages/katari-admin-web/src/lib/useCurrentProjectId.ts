import { useMatch } from "react-router-dom";
import type { ProjectId } from "@/api/types";

/**
 * Pull the active projectId out of the URL. Returns null when the route
 * sits outside the `/project/:projectId/...` branch (= /projects, /env,
 * /settings, /login).
 */
export function useCurrentProjectId(): ProjectId | null {
  const match = useMatch("/project/:projectId/*");
  if (match === null) return null;
  const { projectId } = match.params;
  if (typeof projectId !== "string" || projectId === "") return null;
  return projectId as ProjectId;
}
