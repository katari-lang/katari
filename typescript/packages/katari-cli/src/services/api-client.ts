// Typed fetch wrapper for katari-api-server.
//
// SSoT: snapshot 関連の問い合わせは全部このクライアント経由 (= api-server を
// SSoT として扱う)。CLI は local cache を持たない。

import type {
  AgentDefinition,
  IRModule,
  RawValue,
  SchemaBundle,
} from "katari-runtime";
import type { SidecarBundle } from "../types.js";

export class ApiError extends Error {
  constructor(
    message: string,
    public readonly status: number,
    public readonly body: unknown,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

export type FetchLike = (
  input: Request | URL | string,
  init?: RequestInit,
) => Promise<Response>;

export type ApiClientOptions = {
  baseUrl: string;
  authToken?: string;
  fetch?: FetchLike;
};

// ─── Response shapes (mirrors api-server routes) ───────────────────────────

export type Project = {
  id: string;
  name: string;
  createdAt: string;
};

export type SnapshotSummary = {
  id: string;
  projectId: string;
  createdAt: string;
};

export type Snapshot = SnapshotSummary & {
  irModule: IRModule;
  sidecarBundle: SidecarBundle | null;
  schemaBundle: SchemaBundle;
};

export type AgentRow = {
  id: string;
  delegationId: string;
  snapshotId: string;
  qualifiedName: string;
  // Wire format: raw JSON (the API server applies `valueToRaw` to
  // `Value`s at the boundary).
  args: Record<string, RawValue>;
  state: "running" | "cancelling" | "cancelled" | "succeeded" | "error";
  result?: RawValue;
  errorMessage?: string;
  createdAt: string;
  updatedAt: string;
};

export type ApiPendingEscalation = {
  escalationId: string;
  delegationId: string;
  snapshotId: string;
  agentDefId: unknown;
  args: Record<string, RawValue>;
  state: "open" | "answered" | "cancelled";
  value?: RawValue;
  createdAt: string;
};

// ─── Client ────────────────────────────────────────────────────────────────

export class ApiClient {
  private readonly fetchImpl: FetchLike;

  constructor(private readonly opts: ApiClientOptions) {
    this.fetchImpl = opts.fetch ?? ((input, init) => fetch(input, init));
  }

  /** Returns a new ApiClient that uses the given fetch implementation. */
  withFetch(fetchImpl: FetchLike): ApiClient {
    return new ApiClient({ ...this.opts, fetch: fetchImpl });
  }

  // Projects
  upsertProject(name: string): Promise<Project> {
    return this.post<{ project: Project }>("/project", { name }).then(
      (r) => r.project,
    );
  }

  listProjects(): Promise<Project[]> {
    return this.get<{ projects: Project[] }>("/project").then(
      (r) => r.projects,
    );
  }

  // Snapshots
  uploadSnapshot(input: {
    projectId: string;
    irModule: IRModule;
    sidecarBundle: SidecarBundle | null;
    schemaBundle: SchemaBundle;
  }): Promise<{ snapshotId: string }> {
    return this.post(
      `/project/${encodeURIComponent(input.projectId)}/snapshot`,
      {
        irModule: input.irModule,
        sidecarBundle: input.sidecarBundle,
        schemaBundle: input.schemaBundle,
      },
    );
  }

  listSnapshots(projectId: string): Promise<SnapshotSummary[]> {
    return this.get<{ snapshots: SnapshotSummary[] }>(
      `/project/${encodeURIComponent(projectId)}/snapshot`,
    ).then((r) => r.snapshots);
  }

  latestSnapshot(projectId: string): Promise<Snapshot> {
    return this.get<{ snapshot: Snapshot }>(
      `/project/${encodeURIComponent(projectId)}/snapshot/latest`,
    ).then((r) => r.snapshot);
  }

  // Agents
  startAgent(input: {
    projectId: string;
    snapshotId?: string;
    qualifiedName: string;
    args: Record<string, RawValue>;
  }): Promise<{ agentId: string }> {
    return this.post("/agent", input);
  }

  listAgents(filter?: {
    projectId?: string;
    snapshotId?: string;
  }): Promise<AgentRow[]> {
    const qs = new URLSearchParams();
    if (filter?.projectId !== undefined) qs.set("projectId", filter.projectId);
    if (filter?.snapshotId !== undefined) qs.set("snapshotId", filter.snapshotId);
    const suffix = qs.toString();
    return this.get<{ agents: AgentRow[] }>(
      "/agent" + (suffix ? `?${suffix}` : ""),
    ).then((r) => r.agents);
  }

  getAgent(agentId: string): Promise<AgentRow> {
    return this.get<{ agent: AgentRow }>(
      `/agent/${encodeURIComponent(agentId)}`,
    ).then((r) => r.agent);
  }

  cancelAgent(agentId: string): Promise<AgentRow> {
    return this.post<{ agent: AgentRow }>(
      `/agent/${encodeURIComponent(agentId)}/cancel`,
      {},
    ).then((r) => r.agent);
  }

  // Agent definitions
  listAgentDefinitions(input: {
    projectId: string;
    snapshotId?: string;
  }): Promise<{ definitions: AgentDefinition[]; snapshotId: string }> {
    const qs = new URLSearchParams({ projectId: input.projectId });
    if (input.snapshotId !== undefined) qs.set("snapshotId", input.snapshotId);
    return this.get(`/agent-definition?${qs.toString()}`);
  }

  getAgentDefinition(input: {
    projectId: string;
    snapshotId?: string;
    qualifiedName: string;
  }): Promise<{ definition: AgentDefinition; snapshotId: string }> {
    const seg =
      input.snapshotId !== undefined
        ? encodeURIComponent(input.snapshotId)
        : "latest";
    return this.get(
      `/agent-definition/${encodeURIComponent(input.projectId)}/${seg}/${encodeURIComponent(input.qualifiedName)}`,
    );
  }

  // Escalations
  listEscalations(filter?: {
    projectId?: string;
    snapshotId?: string;
    state?: "open" | "answered" | "cancelled";
  }): Promise<ApiPendingEscalation[]> {
    const qs = new URLSearchParams();
    if (filter?.projectId !== undefined) qs.set("projectId", filter.projectId);
    if (filter?.snapshotId !== undefined) qs.set("snapshotId", filter.snapshotId);
    if (filter?.state !== undefined) qs.set("state", filter.state);
    const suffix = qs.toString();
    return this.get<{ escalations: ApiPendingEscalation[] }>(
      "/escalation" + (suffix ? `?${suffix}` : ""),
    ).then((r) => r.escalations);
  }

  answerEscalation(
    escalationId: string,
    value: RawValue,
  ): Promise<{ ok: boolean }> {
    return this.post(
      `/escalation/${encodeURIComponent(escalationId)}/ack`,
      { value },
    );
  }

  // ─── HTTP primitives ───────────────────────────────────────────────────

  private async get<T>(path: string): Promise<T> {
    return this.request<T>("GET", path);
  }

  private async post<T>(path: string, body: unknown): Promise<T> {
    return this.request<T>("POST", path, body);
  }

  private async request<T>(
    method: string,
    path: string,
    body?: unknown,
  ): Promise<T> {
    const url = `${this.opts.baseUrl.replace(/\/$/, "")}${path}`;
    const headers: Record<string, string> = {};
    if (body !== undefined) headers["content-type"] = "application/json";
    if (this.opts.authToken !== undefined && this.opts.authToken.length > 0) {
      headers["authorization"] = `Bearer ${this.opts.authToken}`;
    }
    let res: Response;
    try {
      res = await this.fetchImpl(url, {
        method,
        headers,
        body: body !== undefined ? JSON.stringify(body) : undefined,
      });
    } catch (err) {
      throw new ApiError(
        `${method} ${path}: network error: ${
          err instanceof Error ? err.message : String(err)
        }`,
        0,
        null,
      );
    }
    if (!res.ok) {
      let parsed: unknown = null;
      try {
        parsed = await res.json();
      } catch {
        /* ignore */
      }
      const msg =
        isObject(parsed) && typeof parsed.error === "string"
          ? parsed.error
          : `HTTP ${res.status}`;
      throw new ApiError(`${method} ${path}: ${msg}`, res.status, parsed);
    }
    return (await res.json()) as T;
  }
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null;
}
