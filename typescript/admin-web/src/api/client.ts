// Thin fetch wrapper over the runtime API: prefixes the base path, unwraps the `{ ok, data }`
// envelope, and raises `ApiError` (code + message from the error body) on failure. The runtime is
// unauthenticated today; an optional stored token is still sent as a Bearer header so a deployment
// behind an authenticating proxy works without a code change.

import type {
  AgentDetail,
  AgentList,
  EnvEntry,
  EnvEntryDetail,
  Escalation,
  FileEntry,
  HeadSnapshot,
  Health,
  Json,
  Page,
  Project,
  Run,
  RunEscalationAudit,
  RunEvent,
  RunEventsPage,
  RunState,
  RunTree,
  SnapshotSummary,
} from "./types";

const BASE = "/api/v1";
const TOKEN_STORAGE_KEY = "katari-console.apiToken";

export class ApiError extends Error {
  readonly code: string;
  readonly status: number;

  constructor(status: number, code: string, message: string) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export function storedApiToken(): string | null {
  return localStorage.getItem(TOKEN_STORAGE_KEY);
}

export function setStoredApiToken(token: string | null): void {
  if (token === null || token === "") {
    localStorage.removeItem(TOKEN_STORAGE_KEY);
  } else {
    localStorage.setItem(TOKEN_STORAGE_KEY, token);
  }
}

function headers(extra?: Record<string, string>): Record<string, string> {
  const token = storedApiToken();
  return {
    ...(token === null ? {} : { Authorization: `Bearer ${token}` }),
    ...extra,
  };
}

async function unwrap<T>(response: Response): Promise<T> {
  const body: unknown = await response.json().catch(() => null);
  if (typeof body === "object" && body !== null && "ok" in body) {
    const envelope = body as
      | { ok: true; data: T }
      | { ok: false; error: { code: string; message: string } };
    if (envelope.ok) return envelope.data;
    throw new ApiError(response.status, envelope.error.code, envelope.error.message);
  }
  throw new ApiError(
    response.status,
    "invalid_response",
    `Unexpected response (${response.status}).`,
  );
}

async function requestJson<T>(method: string, path: string, body?: unknown): Promise<T> {
  const response = await fetch(`${BASE}${path}`, {
    method,
    headers: headers(body === undefined ? {} : { "Content-Type": "application/json" }),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return unwrap<T>(response);
}

const get = <T>(path: string) => requestJson<T>("GET", path);

/** GET a paged list: the `data` array plus the `X-Total-Count` header the paged endpoints set (falling
 *  back to the page length when the header is absent, so a non-paged deployment still reads sanely). */
async function getPage<T>(path: string): Promise<Page<T>> {
  const response = await fetch(`${BASE}${path}`, { headers: headers() });
  const items = await unwrap<T[]>(response);
  const header = response.headers.get("X-Total-Count");
  const total = header === null ? items.length : Number(header);
  return { items, total };
}

/** Build a `?a=1&b=2` suffix from defined params (numbers stringified), or "" when none are set. */
function querySuffix(params: Record<string, string | number | undefined>): string {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined) query.set(key, String(value));
  }
  return query.size === 0 ? "" : `?${query.toString()}`;
}

export const api = {
  health: () => get<Health>("/health"),

  listProjects: () => get<Project[]>("/projects"),
  getProject: (projectId: string) => get<Project>(`/projects/${projectId}`),
  createProject: (body: { name: string; description?: string; readme?: string }) =>
    requestJson<Project>("POST", "/projects", body),
  deleteProject: (projectId: string) =>
    requestJson<{ id: string }>("DELETE", `/projects/${projectId}`),

  listSnapshots: (
    projectId: string,
    filter: { search?: string; limit?: number; offset?: number } = {},
  ) => getPage<SnapshotSummary>(`/projects/${projectId}/snapshots${querySuffix(filter)}`),
  getHeadSnapshot: (projectId: string) =>
    get<HeadSnapshot>(`/projects/${projectId}/snapshots/head`),
  /** Rollback (or roll-forward): move the live head; only new runs follow it. */
  setSnapshotHead: (projectId: string, snapshotId: string) =>
    requestJson<{ id: string }>("PUT", `/projects/${projectId}/snapshots/head`, { snapshotId }),

  listRuns: (
    projectId: string,
    filter: { state?: RunState; search?: string; limit?: number; offset?: number } = {},
  ) => getPage<Run>(`/projects/${projectId}/runs${querySuffix(filter)}`),
  getRun: (projectId: string, runId: string) => get<Run>(`/projects/${projectId}/runs/${runId}`),
  startRun: (
    projectId: string,
    body: { qualifiedName: string; name?: string; snapshotId?: string; argument?: Json },
  ) => requestJson<{ id: string }>("POST", `/projects/${projectId}/runs`, body),
  cancelRun: (projectId: string, runId: string, reason?: string) =>
    requestJson<{ id: string }>("POST", `/projects/${projectId}/runs/${runId}/cancel`, {
      ...(reason === undefined ? {} : { reason }),
    }),
  listRunEscalationAudit: (projectId: string, runId: string) =>
    get<RunEscalationAudit[]>(`/projects/${projectId}/runs/${runId}/escalations`),
  getRunTree: (projectId: string, runId: string) =>
    get<RunTree>(`/projects/${projectId}/runs/${runId}/tree`),
  listRunEvents: (
    projectId: string,
    runId: string,
    options: {
      after?: number;
      offset?: number;
      limit?: number;
      kind?: RunEvent["kind"];
      search?: string;
      order?: "asc" | "desc";
    } = {},
  ) => get<RunEventsPage>(`/projects/${projectId}/runs/${runId}/events${querySuffix(options)}`),

  listEscalations: (projectId: string) => get<Escalation[]>(`/projects/${projectId}/escalations`),
  answerEscalation: (projectId: string, escalationId: string, value: Json) =>
    requestJson<{ id: string }>(
      "POST",
      `/projects/${projectId}/escalations/${escalationId}/answer`,
      {
        value,
      },
    ),
  /** Begin the runtime-hosted OAuth flow for an `oauth`-presentation escalation: the runtime mints the
   *  authorization URL the surface then opens. The escalation itself is answered later by the OAuth
   *  callback, so this returns only the URL to send the user to. 404 when the escalation is gone,
   *  409 when its presentation is not `oauth`. */
  startOauthFlow: (projectId: string, escalationId: string) =>
    requestJson<{ authorizationUrl: string }>(
      "POST",
      `/projects/${projectId}/escalations/${escalationId}/oauth-flow`,
    ),

  listAgents: (projectId: string, snapshotId?: string) =>
    get<AgentList>(
      `/projects/${projectId}/agents${snapshotId === undefined ? "" : `?snapshotId=${snapshotId}`}`,
    ),
  getAgent: (projectId: string, qualifiedName: string, snapshotId?: string) =>
    get<AgentDetail>(
      `/projects/${projectId}/agents/${encodeURIComponent(qualifiedName)}${
        snapshotId === undefined ? "" : `?snapshotId=${snapshotId}`
      }`,
    ),

  listFiles: (projectId: string, filter: { limit?: number; offset?: number } = {}) =>
    getPage<FileEntry>(`/projects/${projectId}/files${querySuffix(filter)}`),
  uploadFile: async (projectId: string, file: File) => {
    const response = await fetch(`${BASE}/projects/${projectId}/files`, {
      method: "POST",
      headers: headers({ "Content-Type": file.type || "application/octet-stream" }),
      body: file,
    });
    return unwrap<{ id: string; hash: string; size: number }>(response);
  },
  deleteFile: (projectId: string, fileId: string) =>
    requestJson<{ id: string }>("DELETE", `/projects/${projectId}/files/${fileId}`),
  /** Download bytes (the one endpoint outside the envelope); the caller owns the object URL. */
  downloadFile: async (projectId: string, fileId: string): Promise<Blob> => {
    const response = await fetch(`${BASE}/projects/${projectId}/files/${fileId}`, {
      headers: headers(),
    });
    if (!response.ok) {
      throw new ApiError(
        response.status,
        "download_failed",
        `Download failed (${response.status}).`,
      );
    }
    return response.blob();
  },

  listEnv: (projectId: string) => get<EnvEntry[]>(`/projects/${projectId}/env`),
  getEnvEntry: (projectId: string, key: string) =>
    get<EnvEntryDetail>(`/projects/${projectId}/env/${encodeURIComponent(key)}`),
  setEnvEntry: (projectId: string, key: string, body: { value: string; isSecret?: boolean }) =>
    requestJson<{ key: string }>(
      "PUT",
      `/projects/${projectId}/env/${encodeURIComponent(key)}`,
      body,
    ),
  deleteEnvEntry: (projectId: string, key: string) =>
    requestJson<{ key: string }>("DELETE", `/projects/${projectId}/env/${encodeURIComponent(key)}`),
};
