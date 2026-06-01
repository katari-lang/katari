// Typed wrapper around fetch. Pulls baseUrl / apiKey from ApiKeyContext and
// raises a typed ApiError on non-2xx so callers can branch on status / code.

import type { RawValue, SchemaBundle } from "@katari-lang/runtime";
import type {
  AgentWire,
  EnvEntry,
  EscalationId,
  EscalationState,
  EscalationWire,
  FileWire,
  Project,
  ProjectId,
  RefStateWire,
  RunId,
  RunRowWire,
  RunState,
  RunTree,
  Snapshot,
  SnapshotId,
  SnapshotSummary,
} from "./types";

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
  let parsed: unknown;
  const contentType = res.headers.get("content-type") ?? "";
  if (contentType.includes("application/json")) {
    parsed = await res.json().catch(() => undefined);
  } else {
    parsed = await res.text().catch(() => undefined);
  }
  // Auto-logout on 401: clear the stored API key and bounce to /login
  // so the user sees the login form instead of silent failures.
  // Skip if we're already on /login to avoid an infinite redirect loop.
  if (
    res.status === 401 &&
    typeof window !== "undefined" &&
    window.location.pathname !== "/login"
  ) {
    window.localStorage.removeItem("katari-admin.apiKey");
    window.location.href = "/login";
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
    listProjects: (params?: { limit?: number; cursor?: string }) =>
      request<{ projects: Project[]; nextCursor: string | null }>(
        config,
        "GET",
        withQuery("/project", params),
      ),
    getProject: (id: ProjectId) => request<{ project: Project }>(config, "GET", `/project/${id}`),
    getProjectByName: (name: string) =>
      request<{ project: Project }>(config, "GET", `/project/by-name/${encodeURIComponent(name)}`),

    // Snapshots (mounted under /project/:projectId/snapshot)
    listSnapshots: (projectId: ProjectId, params?: { limit?: number; cursor?: string }) =>
      request<{ snapshots: SnapshotSummary[]; nextCursor: string | null }>(
        config,
        "GET",
        withQuery(`/project/${projectId}/snapshot`, params),
      ),
    getSnapshotLatest: (projectId: ProjectId) =>
      request<{ snapshot: Snapshot }>(config, "GET", `/project/${projectId}/snapshot/latest`),
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

    // Agents (snapshot-scoped). `snapshotId === "latest"` is a
    // server-side alias for the project's most-recent snapshot.
    listAgents: (params: { projectId: ProjectId; snapshotId?: SnapshotId | "latest" }) =>
      request<{ agents: AgentWire[]; snapshotId: SnapshotId }>(
        config,
        "GET",
        `/project/${params.projectId}/snapshot/${params.snapshotId ?? "latest"}/agent`,
      ),
    getAgent: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId | "latest";
      qualifiedName: string;
    }) =>
      request<{ agent: AgentWire; snapshotId: SnapshotId }>(
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
      cursor?: string;
    }) =>
      request<{ runs: RunRowWire[]; nextCursor: string | null }>(
        config,
        "GET",
        withQuery(`/project/${params.projectId}/run`, {
          snapshotId: params.snapshotId,
          state: params.state,
          limit: params.limit,
          cursor: params.cursor,
        }),
      ),
    getRun: (projectId: ProjectId, id: RunId) =>
      request<{ run: RunRowWire }>(config, "GET", `/project/${projectId}/run/${id}`),
    /** Live entity tree rooted at `runId`. Polled by the run detail page. */
    getRunTree: (projectId: ProjectId, runId: RunId) =>
      request<{ tree: RunTree }>(config, "GET", `/project/${projectId}/run/${runId}/tree`),
    startRun: (input: {
      projectId: ProjectId;
      snapshotId?: SnapshotId;
      qualifiedName: string;
      name?: string | null;
      args: Record<string, RawValue>;
    }) =>
      request<{ runId: RunId }>(config, "POST", `/project/${input.projectId}/run`, {
        snapshotId: input.snapshotId,
        qualifiedName: input.qualifiedName,
        name: input.name ?? null,
        args: input.args,
      }),
    cancelRun: (projectId: ProjectId, id: RunId) =>
      request<{ run: RunRowWire }>(config, "POST", `/project/${projectId}/run/${id}/cancel`),

    // Escalations (project-scoped).
    listEscalations: (params: {
      projectId: ProjectId;
      snapshotId?: SnapshotId;
      runId?: RunId;
      state?: EscalationState;
      limit?: number;
      cursor?: string;
    }) =>
      request<{ escalations: EscalationWire[]; nextCursor: string | null }>(
        config,
        "GET",
        withQuery(`/project/${params.projectId}/escalation`, {
          snapshotId: params.snapshotId,
          runId: params.runId,
          state: params.state,
          limit: params.limit,
          cursor: params.cursor,
        }),
      ),
    getEscalation: (projectId: ProjectId, id: EscalationId) =>
      request<{ escalation: EscalationWire }>(
        config,
        "GET",
        `/project/${projectId}/escalation/${id}`,
      ),
    answerEscalation: (projectId: ProjectId, id: EscalationId, value: RawValue) =>
      request<{ ok: boolean }>(config, "POST", `/project/${projectId}/escalation/${id}/ack`, {
        value,
      }),

    // Env (per-project; mounted under /project/:projectId/env).
    listEnv: (projectId: ProjectId) =>
      request<{ entries: EnvEntry[] }>(config, "GET", `/project/${projectId}/env`),
    getEnv: (projectId: ProjectId, key: string) =>
      request<EnvEntry>(config, "GET", `/project/${projectId}/env/${encodeURIComponent(key)}`),
    upsertEnv: (projectId: ProjectId, entry: { key: string; value: string; isSecret: boolean }) =>
      request<{ ok: boolean }>(config, "PUT", `/project/${projectId}/env`, entry),
    deleteEnv: (projectId: ProjectId, key: string) =>
      request<{ ok: boolean }>(
        config,
        "DELETE",
        `/project/${projectId}/env/${encodeURIComponent(key)}`,
      ),

    // Files (persistent api_files; mounted under /project/:projectId/file).
    listFiles: (projectId: ProjectId) =>
      request<{ files: FileWire[] }>(config, "GET", `/project/${projectId}/file`),
    /** Upload raw bytes. The body is the file itself; the display name +
     *  content type ride the query / Content-Type so the JSON `request`
     *  helper is bypassed for this one binary path. */
    uploadFile: (projectId: ProjectId, file: File, displayName?: string) =>
      uploadBytes(config, projectId, file, displayName),
    deleteFile: (projectId: ProjectId, id: string) =>
      request<{ ok: boolean }>(config, "DELETE", `/project/${projectId}/file/${id}`),

    /** Consume-side metadata of a value ref (display name / size / type). Lets
     *  the value viewer label a file ref by its name (the wire value carries
     *  only the ref handle). */
    valueState: (projectId: ProjectId, module: RefModule, id: string) =>
      request<RefStateWire>(
        config,
        "GET",
        `/project/${projectId}/value/${module}/ref/${encodeURIComponent(id)}/state`,
      ),

    /** Authenticated fetch of a value ref's bytes (data plane). Works for any
     *  module (core / ffi / api); returns a Blob the caller turns into a
     *  download. Kept out of `request` (binary, not JSON). */
    valueBlob: (projectId: ProjectId, module: RefModule, id: string) =>
      fetchValueBlob(config, projectId, module, id),
  };
}

/** Wire module owning a value ref. */
export type RefModule = "core" | "ffi" | "api";

async function fetchValueBlob(
  config: ApiClientConfig,
  projectId: ProjectId,
  module: RefModule,
  id: string,
): Promise<Blob> {
  const url = `${config.baseUrl.replace(/\/$/, "")}/project/${projectId}/value/${module}/ref/${encodeURIComponent(id)}`;
  const res = await fetch(url, { headers: { Authorization: `Bearer ${config.apiKey}` } });
  if (
    res.status === 401 &&
    typeof window !== "undefined" &&
    window.location.pathname !== "/login"
  ) {
    window.localStorage.removeItem("katari-admin.apiKey");
    window.location.href = "/login";
  }
  if (!res.ok) {
    throw new ApiError(res.status, undefined, `value download failed with ${res.status}`);
  }
  return res.blob();
}

/** Binary upload path (not JSON), kept out of `request` so that stays
 *  JSON-only. Mirrors `request`'s auth + 401 handling. */
async function uploadBytes(
  config: ApiClientConfig,
  projectId: ProjectId,
  file: File,
  displayName?: string,
): Promise<{ file: FileWire }> {
  // The display name defaults to the picked file's name; an explicit override
  // (operator typed one) wins.
  const label = displayName !== undefined && displayName !== "" ? displayName : file.name;
  const name = label !== "" ? `?name=${encodeURIComponent(label)}` : "";
  const url = `${config.baseUrl.replace(/\/$/, "")}/project/${projectId}/file${name}`;
  const headers: Record<string, string> = {
    Authorization: `Bearer ${config.apiKey}`,
  };
  if (file.type !== "") headers["content-type"] = file.type;
  const res = await fetch(url, { method: "POST", headers, body: file });
  const parsed = (await res.json().catch(() => undefined)) as unknown;
  if (
    res.status === 401 &&
    typeof window !== "undefined" &&
    window.location.pathname !== "/login"
  ) {
    window.localStorage.removeItem("katari-admin.apiKey");
    window.location.href = "/login";
  }
  if (!res.ok) {
    const message =
      parsed !== null && typeof parsed === "object" && "error" in parsed
        ? String((parsed as { error: unknown }).error)
        : `upload failed with ${res.status}`;
    throw new ApiError(res.status, parsed, message);
  }
  return parsed as { file: FileWire };
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
