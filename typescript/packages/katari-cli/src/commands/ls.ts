// `katari ls [agents | agent-defs | snapshots | projects]` — list views.
//
// 引数省略 → どれを ls するか select。SSoT は api-server。

import * as p from "@clack/prompts";
import pc from "picocolors";
import { ApiClient, ApiError } from "../services/api-client.js";
import { loadConfig } from "../services/config.js";
import {
  formatQualifiedName,
  relativeTime,
  shortId,
  stateBadge,
  summarizeArgs,
} from "../prompt/picker-utils.js";
import { PromptCancelled } from "../prompt/schema-prompt.js";

export type LsTarget = "agents" | "agent-defs" | "snapshots" | "projects";

export type LsOptions = {
  target?: LsTarget;
  project?: string;
  snapshot?: string;
};

export async function lsCmd(opts: LsOptions): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari ls ")));

  const target = opts.target ?? (await pickTarget());
  const { config } = await loadConfig();
  const api = new ApiClient({
    baseUrl: config.api.url,
    authToken: config.api.auth,
  });

  try {
    switch (target) {
      case "projects":
        await lsProjects(api);
        break;
      case "snapshots":
        await lsSnapshots(api, opts.project ?? config.project);
        break;
      case "agents":
        await lsAgents(api, opts.project ?? config.project);
        break;
      case "agent-defs":
        await lsAgentDefs(
          api,
          opts.project ?? config.project,
          opts.snapshot,
        );
        break;
    }
    p.outro("done");
  } catch (err) {
    handleApiError(err);
  }
}

async function pickTarget(): Promise<LsTarget> {
  const choice = await p.select({
    message: "List what?",
    options: [
      {
        value: "agents" as const,
        label: "agents",
        hint: "running / completed agent instances",
      },
      {
        value: "agent-defs" as const,
        label: "agent-defs",
        hint: "agent definitions in the latest snapshot",
      },
      {
        value: "snapshots" as const,
        label: "snapshots",
        hint: "snapshots in this project",
      },
      {
        value: "projects" as const,
        label: "projects",
        hint: "all projects",
      },
    ],
  });
  if (p.isCancel(choice)) {
    p.cancel("cancelled");
    throw new PromptCancelled();
  }
  return choice as LsTarget;
}

async function lsProjects(api: ApiClient): Promise<void> {
  const projects = await api.listProjects();
  if (projects.length === 0) {
    p.note(pc.dim("(no projects)"), "projects");
    return;
  }
  const lines = projects.map(
    (proj) =>
      `${pc.cyan(proj.name).padEnd(30)} ${pc.dim(`#${shortId(proj.id)}`)}  ${pc.dim(relativeTime(proj.createdAt))}`,
  );
  p.note(lines.join("\n"), `projects (${projects.length})`);
}

async function lsSnapshots(api: ApiClient, projectName: string): Promise<void> {
  const project = await api.upsertProject(projectName);
  const snaps = await api.listSnapshots(project.id);
  if (snaps.length === 0) {
    p.note(pc.dim("(no snapshots)"), `${project.name} → snapshots`);
    return;
  }
  const lines = snaps.map(
    (s) =>
      `${pc.cyan(`#${shortId(s.id)}`)}  ${pc.dim(relativeTime(s.createdAt))}  ${pc.dim(s.id)}`,
  );
  p.note(lines.join("\n"), `${project.name} → snapshots (${snaps.length})`);
}

async function lsAgents(api: ApiClient, projectName: string): Promise<void> {
  const project = await api.upsertProject(projectName);
  const agents = await api.listAgents({ projectId: project.id });
  if (agents.length === 0) {
    p.note(pc.dim("(no agents)"), `${project.name} → agents`);
    return;
  }
  const lines = agents.map((a) => {
    const argSummary =
      Object.keys(a.args).length > 0 ? `  ${pc.dim(summarizeArgs(a.args, 32))}` : "";
    return [
      stateBadge(a.state).padEnd(20),
      pc.cyan(a.qualifiedName).padEnd(28),
      pc.dim(`#${shortId(a.id)}`),
      pc.dim(relativeTime(a.createdAt)),
      argSummary,
    ].join("  ");
  });
  p.note(lines.join("\n"), `${project.name} → agents (${agents.length})`);
}

async function lsAgentDefs(
  api: ApiClient,
  projectName: string,
  snapshotIdOpt: string | undefined,
): Promise<void> {
  const project = await api.upsertProject(projectName);
  const result = await api.listAgentDefinitions({
    projectId: project.id,
    snapshotId: snapshotIdOpt,
  });
  if (result.definitions.length === 0) {
    p.note(
      pc.dim("(no agent definitions)"),
      `${project.name} → agent-defs (snapshot #${shortId(result.snapshotId)})`,
    );
    return;
  }
  const lines = result.definitions.map(
    (d) =>
      `${pc.cyan(formatQualifiedName(d.qualifiedName)).padEnd(32)} ${
        d.description !== undefined ? pc.dim(d.description) : ""
      }`,
  );
  p.note(
    lines.join("\n"),
    `${project.name} → agent-defs (snapshot #${shortId(result.snapshotId)}, ${result.definitions.length})`,
  );
}

function handleApiError(err: unknown): never {
  if (err instanceof ApiError) {
    p.cancel(`${err.message} (HTTP ${err.status})`);
  } else if (err instanceof PromptCancelled) {
    process.exit(130);
  } else {
    p.cancel(err instanceof Error ? err.message : String(err));
  }
  process.exit(1);
}
