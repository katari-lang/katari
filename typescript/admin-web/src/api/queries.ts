// React-query hooks per resource. Live resources (runs, escalations) poll while something is in
// flight and stop on their own once everything is terminal, so an idle console makes no traffic.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api } from "./client";
import type { Escalation, Json, Run, RunState } from "./types";

const LIVE_POLL_MILLISECONDS = 2500;

export const isLiveRun = (run: Run): boolean =>
  run.state === "running" || run.state === "cancelling";

export function useProjects() {
  return useQuery({ queryKey: ["projects"], queryFn: api.listProjects });
}

export function useProject(projectId: string) {
  return useQuery({ queryKey: ["projects", projectId], queryFn: () => api.getProject(projectId) });
}

export function useSnapshots(projectId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "snapshots"],
    queryFn: () => api.listSnapshots(projectId),
  });
}

export function useHeadSnapshot(projectId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "snapshots", "head"],
    queryFn: () => api.getHeadSnapshot(projectId),
  });
}

export function useRuns(projectId: string, filter: { state?: RunState; limit?: number } = {}) {
  return useQuery({
    queryKey: ["projects", projectId, "runs", filter],
    queryFn: () => api.listRuns(projectId, filter),
    refetchInterval: (query) =>
      (query.state.data ?? []).some(isLiveRun) ? LIVE_POLL_MILLISECONDS : false,
  });
}

export function useRun(projectId: string, runId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "runs", runId],
    queryFn: () => api.getRun(projectId, runId),
    refetchInterval: (query) => {
      const run = query.state.data;
      return run !== undefined && isLiveRun(run) ? LIVE_POLL_MILLISECONDS : false;
    },
  });
}

export function useRunTree(projectId: string, runId: string, live: boolean) {
  return useQuery({
    queryKey: ["projects", projectId, "runs", runId, "tree"],
    queryFn: () => api.getRunTree(projectId, runId),
    refetchInterval: live ? LIVE_POLL_MILLISECONDS : false,
  });
}

export function useRunEvents(projectId: string, runId: string, live: boolean) {
  return useQuery({
    queryKey: ["projects", projectId, "runs", runId, "events"],
    // One capped page from the start: the journal is append-only, so a full refetch while live always
    // extends what was shown (no reordering); a run past the cap notes its truncation in the card.
    queryFn: () => api.listRunEvents(projectId, runId, { limit: 1000 }),
    refetchInterval: live ? LIVE_POLL_MILLISECONDS : false,
  });
}

export function useRunEscalationAudit(projectId: string, runId: string, live: boolean) {
  return useQuery({
    queryKey: ["projects", projectId, "runs", runId, "escalations"],
    queryFn: () => api.listRunEscalationAudit(projectId, runId),
    refetchInterval: live ? LIVE_POLL_MILLISECONDS : false,
  });
}

export function useEscalations(projectId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "escalations"],
    queryFn: () => api.listEscalations(projectId),
    refetchInterval: LIVE_POLL_MILLISECONDS,
  });
}

export function useAgents(projectId: string, snapshotId?: string) {
  return useQuery({
    queryKey: ["projects", projectId, "agents", snapshotId ?? "head"],
    queryFn: () => api.listAgents(projectId, snapshotId),
  });
}

export function useAgent(projectId: string, qualifiedName: string, snapshotId?: string) {
  return useQuery({
    queryKey: ["projects", projectId, "agents", snapshotId ?? "head", qualifiedName],
    queryFn: () => api.getAgent(projectId, qualifiedName, snapshotId),
  });
}

export function useFiles(projectId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "files"],
    queryFn: () => api.listFiles(projectId),
  });
}

export function useEnv(projectId: string) {
  return useQuery({
    queryKey: ["projects", projectId, "env"],
    queryFn: () => api.listEnv(projectId),
  });
}

export function useStartRun(projectId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      qualifiedName: string;
      name?: string;
      snapshotId?: string;
      argument?: Json;
    }) => api.startRun(projectId, body),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects", projectId, "runs"] }),
  });
}

export function useCancelRun(projectId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ runId, reason }: { runId: string; reason?: string }) =>
      api.cancelRun(projectId, runId, reason),
    onSuccess: () => queryClient.invalidateQueries({ queryKey: ["projects", projectId, "runs"] }),
  });
}

export function useAnswerEscalation(projectId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ escalationId, value }: { escalationId: string; value: Json }) =>
      api.answerEscalation(projectId, escalationId, value),
    onSuccess: (_result, { escalationId }) => {
      // Drop the answered escalation from the inbox immediately. The runtime closes it asynchronously,
      // so invalidating (a refetch) would race that and momentarily re-add it; the 2.5s poll reconciles.
      queryClient.setQueryData<Escalation[]>(["projects", projectId, "escalations"], (current) =>
        current?.filter((escalation) => escalation.id !== escalationId),
      );
      queryClient.invalidateQueries({ queryKey: ["projects", projectId, "runs"] });
    },
  });
}
