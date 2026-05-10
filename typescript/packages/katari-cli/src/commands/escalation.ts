// `katari escalation list` / `katari escalation answer [<id>] [--value <json>]`
//
// AI から user への質問 (= api_pending_escalations) を一覧 / 応答する。

import * as p from "@clack/prompts";
import pc from "picocolors";
import { ApiClient, ApiError, type AgentRow } from "../services/api-client.js";
import { loadConfig } from "../services/config.js";
import {
  relativeTime,
  selectEscalation,
  shortId,
  summarizeAgentDefId,
  summarizeArgs,
} from "../prompt/picker-utils.js";
import {
  PromptCancelled,
  promptForSchema,
} from "../prompt/schema-prompt.js";
import type { Value } from "../types.js";

export type EscalationListOptions = {
  project?: string;
  state?: "open" | "answered" | "cancelled";
};

export type EscalationAnswerOptions = {
  escalationId?: string;
  value?: string;
  project?: string;
};

export async function escalationListCmd(
  opts: EscalationListOptions,
): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari escalation list ")));
  const { config } = await loadConfig();
  const api = new ApiClient({
    baseUrl: config.api.url,
    authToken: config.api.auth,
  });
  try {
    const project = await api.upsertProject(opts.project ?? config.project);
    const escalations = await api.listEscalations({
      projectId: project.id,
      state: opts.state ?? "open",
    });
    if (escalations.length === 0) {
      p.note(pc.dim("(none)"), `${project.name} → escalations (${opts.state ?? "open"})`);
      p.outro("done");
      return;
    }
    const agentByDelegationId = await fetchAgentsByDelegationIds(
      api,
      escalations.map((e) => e.delegationId),
    );
    const lines = escalations.map((e) => {
      const agent = agentByDelegationId.get(e.delegationId);
      const fromAgent = agent !== undefined
        ? pc.cyan(agent.qualifiedName)
        : pc.dim(`<delegation ${shortId(e.delegationId)}>`);
      return [
        pc.dim(`#${shortId(e.escalationId)}`),
        summarizeAgentDefId(e.agentDefId).padEnd(28),
        `from ${fromAgent}`,
        pc.dim(relativeTime(e.createdAt)),
        Object.keys(e.args).length > 0 ? pc.dim(`args: ${summarizeArgs(e.args, 24)}`) : "",
      ].filter((s) => s.length > 0).join("  ");
    });
    p.note(
      lines.join("\n"),
      `${project.name} → escalations (${escalations.length})`,
    );
    p.outro("done");
  } catch (err) {
    handleApiError(err);
  }
}

export async function escalationAnswerCmd(
  opts: EscalationAnswerOptions,
): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari escalation answer ")));
  const { config } = await loadConfig();
  const api = new ApiClient({
    baseUrl: config.api.url,
    authToken: config.api.auth,
  });
  try {
    const project = await api.upsertProject(opts.project ?? config.project);

    let escalationId = opts.escalationId;
    if (escalationId === undefined) {
      const open = await api.listEscalations({
        projectId: project.id,
        state: "open",
      });
      const agentByDelegationId = await fetchAgentsByDelegationIds(
        api,
        open.map((e) => e.delegationId),
      );
      try {
        const chosen = await selectEscalation(
          open,
          agentByDelegationId,
          "Answer which escalation?",
        );
        escalationId = chosen.escalationId;
      } catch (err) {
        if (err instanceof PromptCancelled) {
          p.cancel("cancelled");
          process.exit(130);
        }
        throw err;
      }
    }

    let value: Value;
    if (opts.value !== undefined) {
      try {
        value = JSON.parse(opts.value);
      } catch (err) {
        p.cancel(
          `--value must be valid JSON: ${err instanceof Error ? err.message : String(err)}`,
        );
        process.exit(1);
      }
    } else {
      // v1: answer schema is unknown (escalate's agentDefId currently
      // contains a synthetic placeholder). Fall back to free-form JSON
      // text input until the runtime carries the request's `returns`
      // schema through the escalate event.
      const text = await p.text({
        message: "Answer (JSON)",
        placeholder: '{"kind": "string", "value": "ok"}',
        validate: (v) => {
          if (v.length === 0) return "required";
          try {
            JSON.parse(v);
            return undefined;
          } catch {
            return "must be valid JSON";
          }
        },
      });
      if (p.isCancel(text)) {
        p.cancel("cancelled");
        process.exit(130);
      }
      value = JSON.parse(text);
    }

    const spinner = p.spinner();
    spinner.start("Answering");
    try {
      await api.answerEscalation(escalationId, value);
      spinner.stop(pc.green("✓ answered"));
      p.outro(`escalation #${shortId(escalationId)} resolved`);
    } catch (err) {
      spinner.stop(pc.red("Answer failed"), 1);
      handleApiError(err);
    }
  } catch (err) {
    handleApiError(err);
  }
}

async function fetchAgentsByDelegationIds(
  api: ApiClient,
  delegationIds: string[],
): Promise<Map<string, AgentRow>> {
  const map = new Map<string, AgentRow>();
  // delegationId === agentId in current api-server impl, so we can fetch
  // each agent row directly. Best effort: ignore individual lookups that
  // fail (agent row may have been pruned).
  await Promise.all(
    delegationIds.map(async (d) => {
      try {
        const row = await api.getAgent(d);
        map.set(d, row);
      } catch {
        /* ignore */
      }
    }),
  );
  return map;
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

// Suppress unused warnings for shared imports
void promptForSchema;
