// `katari cancel [<agentId>]` — cancel a running agent.
//
// agentId 不足 → running agents から select。各 row は qualifiedName +
// 起動時刻 + args summary 付きで表示される。

import * as p from "@clack/prompts";
import pc from "picocolors";
import { ApiClient, ApiError } from "../services/api-client.js";
import { loadConfig } from "../services/config.js";
import {
  selectAgent,
  shortId,
  stateBadge,
} from "../prompt/picker-utils.js";
import { PromptCancelled } from "../prompt/schema-prompt.js";

export type CancelOptions = {
  agentId?: string;
  project?: string;
};

export async function cancelCmd(opts: CancelOptions): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari cancel ")));

  const { config } = await loadConfig();
  const projectName = opts.project ?? config.project;
  const api = new ApiClient({
    baseUrl: config.api.url,
    authToken: config.api.auth,
  });

  let agentId = opts.agentId;
  if (agentId === undefined) {
    let project;
    try {
      project = await api.upsertProject(projectName);
    } catch (err) {
      handleApiError(err);
      return;
    }
    let agents;
    try {
      agents = await api.listAgents({ projectId: project.id });
    } catch (err) {
      handleApiError(err);
      return;
    }
    const cancellable = agents.filter(
      (a) => a.state === "running",
    );
    try {
      const chosen = await selectAgent(
        cancellable,
        "Cancel which running agent?",
      );
      agentId = chosen.id;
    } catch (err) {
      if (err instanceof PromptCancelled) {
        p.cancel("cancelled");
        process.exit(130);
      }
      throw err;
    }
  }

  const spinner = p.spinner();
  spinner.start(`Cancelling ${pc.dim(`#${shortId(agentId)}`)}`);
  try {
    const row = await api.cancelAgent(agentId);
    spinner.stop(
      `${stateBadge(row.state)} ${pc.cyan(row.qualifiedName)} ${pc.dim(`#${shortId(row.id)}`)}`,
    );
    p.outro("done");
  } catch (err) {
    spinner.stop(pc.red("Cancel failed"), 1);
    handleApiError(err);
  }
}

function handleApiError(err: unknown): never {
  if (err instanceof ApiError) {
    p.cancel(`${err.message} (HTTP ${err.status})`);
  } else {
    p.cancel(err instanceof Error ? err.message : String(err));
  }
  process.exit(1);
}
