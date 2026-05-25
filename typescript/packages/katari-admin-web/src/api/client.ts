// Typed wrapper around fetch. Pulls baseUrl / apiKey from ApiKeyContext and
// raises a typed ApiError on non-2xx so callers can branch on status / code.

import type {
  AgentDefinitionWire,
  DelegationTree,
  EnvEntry,
  EscalationId,
  EscalationState,
  EscalationWire,
  Project,
  ProjectId,
  RunId,
  RunRowWire,
  RunState,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
} from "./types";
import type { RawValue, SchemaBundle } from "@katari-lang/runtime";

export class ApiError extends Error {
  status: number;
  body: unknown;
  constructor(status: number, body: unknown, message: string) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

export type ApiClientConfig = {
  baseUrl: string;
  apiKey: string;
};

async function request<T>(
  config: ApiClientConfig,
  method: string,
  path: string,
  body?: unknown,
): Promise<T> {
  const url = `${config.baseUrl.replace(/\/$/, "")}${path}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${config.apiKey}`,
  };
  if (body !== undefined) {
    headers["content-type"] = "application/json";
  }
  const res = await fetch(url, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let parsed: unknown = undefined;
  const contentType = res.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    parsed = await res.json().catch(() => undefined);
  } else {
    parsed = await res.text().catch(() => undefined);
  }
  if (!res.ok) {
    const message =
      parsed !== null && typeof parsed === "object" && "error" in parsed
        ? String((parsed as { error: unknown }).error)
        : `${method} ${path} failed with ${res.status}`;
    throw new ApiError(res.status, parsed, message);
  }
  return parsed as T;
}

export function createApiClient(config: ApiClientConfig) {
  return {
    // Health
    healthz: () => request<string>(config, "GET", "/healthz"),

    // Projects
    listProjects: (params?: { limit?: number; offset?: number }) =>
      request<{ projects: Project[] }>(
        config,
        "GET",
        withQuery("/project", params),
      ),
    getProject: (id: ProjectId) =>
      request<{ project: Project }>(config, "GET", `/project/${id}`),
    getProjectByName: (name: string) =>
      request<{ project: Project }>(
        config,
        "GET",
        `/project/by-name/${encodeURIComponent(name)}`,
      ),

    // Snapshots (mounted under /project/:projectId/snapshot)
    listSnapshots: (
      projectId: ProjectId,
      params?: { limit?: number; offset?: number },
    ) =>
      request<{ snapshots: SnapshotSummary[] }>(
        config,
        "GET",
        withQuery(`/project/${projectId}/snapshot`, params),
      ),
    getSnapshotLatest: (projectId: ProjectId) =>
      request<{ snapshot: Snapshot }>(
        config,
        "GET",
        `/project/${projectId}/snapshot/latest`,
      ),
    getSnapshot: (projectId: ProjectId, snapshotId: SnapshotId) =>
      request<{ snapshot: Snapshot }>(
        config,
        "GET",
        `/project/${projectId}/snapshot/${snapshotId}`,
      ),
    getSnapshotSchema: (projectId: ProjectId, snapshotId: SnapshotId) =>
      request<{ schemaBundle: SchemaBundle }>(
        config,
        "GET",
        `/project/${projectId}/snapshot/${snapshotId}/schema`,
      ),

    // Agent definitions (snapshot-scoped). `snapshotId === "latest"` is a
    // server-side alias for the project's most-recent snapshot.
    listAgentAgents: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId | "latest";
    }) =>
      request<{ definitions: AgentDefinitionWire[]; snapshotId: SnapshotId }>(
        config,
        "GET",
        `/project/${params.projectId}/snapshot/${params.snapshotId ?? "latest"}/agent`,
      ),
    getAgentDefinition: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId | "latest";
      qualifiedName: string;
    }) =>
      request<{ definition: AgentDefinitionWire; snapshotId: SnapshotId }>(
        config,
        "GET",
        `/project/${params.projectId}/snapshot/${params.snapshotId ?? "latest"}/agent/${encodeURIComponent(params.qualifiedName)}`,
      ),

    // Runs (= operator-launched root delegations; project-scoped).
    listRuns: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId;
      state?: RunState;
      limit?: number;
      offset?: number;
    }) =>
      request<{ runs: RunRowWire[] }>(
        config,
        "GET",
        withQuery(`/project/${params.projectId}/run`, {
          snapshotId: params.snapshotId,
          state: params.state,
          limit: params.limit,
          offset: params.offset,
        }),
      ),
    getRun: (projectId: ProjectId, id: RunId) =>
      request<{ run: RunRowWire }>(
        config,
        "GET",
        `/project/${projectId}/run/${id}`,
      ),
    /** Live delegation tree rooted at `runId`. Polled by the run detail page. */
    getRunTree: (projectId: ProjectId, runId: RunId) =>
      request<{ tree: DelegationTree }>(
        config,
        "GET",
        `/project/${projectId}/run/${runId}/tree`,
      ),
    startRun: (input: {
      projectId: ProjectId;
      snapshotId?: SnapshotId;
      qualifiedName: string;
      name?: string | null;
      args: Record<string, RawValue>;
    }) =>
      request<{ runId: RunId }>(
        config,
        "POST",
        `/project/${input.projectId}/run`,
        {
          snapshotId: input.snapshotId,
          qualifiedName: input.qualifiedName,
          name: input.name ?? null,
          args: input.args,
        },
      ),
    cancelRun: (projectId: ProjectId, id: RunId) =>
      request<{ run: RunRowWire }>(
        config,
        "POST",
        `/project/${projectId}/run/${id}/cancel`,
      ),

    // Escalations (project-scoped).
    listEscalations: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId;
      state?: EscalationState;
      limit?: number;
      offset?: number;
    }) =>
      request<{ escalations: EscalationWire[] }>(
        config,
        "GET",
        withQuery(`/project/${params.projectId}/escalation`, {
          snapshotId: params.snapshotId,
          state: params.state,
          limit: params.limit,
          offset: params.offset,
        }),
      ),
    getEscalation: (projectId: ProjectId, id: EscalationId) =>
      request<{ escalation: EscalationWire }>(
        config,
        "GET",
        `/project/${projectId}/escalation/${id}`,
      ),
    answerEscalation: (
      projectId: ProjectId,
      id: EscalationId,
      value: RawValue,
    ) =>
      request<{ ok: boolean }>(
        config,
        "POST",
        `/project/${projectId}/escalation/${id}/ack`,
        { value },
      ),

    // Env
    listEnv: () => request<{ entries: EnvEntry[] }>(config, "GET", "/env"),
    getEnv: (key: string) =>
      request<EnvEntry>(config, "GET", `/env/${encodeURIComponent(key)}`),
    upsertEnv: (entry: { key: string; value: string; isSecret: boolean }) =>
      request<{ ok: boolean }>(config, "PUT", "/env", entry),
    deleteEnv: (key: string) =>
      request<{ ok: boolean }>(
        config,
        "DELETE",
        `/env/${encodeURIComponent(key)}`,
      ),
  };
}

export type ApiClient = ReturnType<typeof createApiClient>;

function withQuery(
  path: string,
  params: Record<string, string | number | boolean | undefined> | undefined,
): string {
  if (params === undefined) return path;
  const search = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v !== undefined) search.set(k, String(v));
  }
  const queryString = search.toString();
  return queryString === "" ? path : `${path}?${queryString}`;
}
