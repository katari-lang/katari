// The snapshot an escalation's answer form should pin `$agent` references to: the raising run's
// snapshot. Falls back to the head-resolved sentinel when the run (or its pin) is gone.

import { useQuery } from "@tanstack/react-query";
import { api } from "../../api/client";
import type { FormContext } from "../schema-form/SchemaForm";

export function useRunSnapshot(projectId: string, runId: string): string {
  const run = useQuery({
    queryKey: ["projects", projectId, "runs", runId],
    queryFn: () => api.getRun(projectId, runId),
  });
  return run.data?.snapshotId ?? "";
}

export function FormContextForRun(projectId: string, snapshotId: string): FormContext {
  return { projectId, snapshotId };
}
