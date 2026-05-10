// `katari run [<qname>] [--snapshot <id>] [--args <json>]` — start an agent.
//
// SSoT: agent definitions / latest snapshot は api-server から取る。CLI は
// local の schema bundle を参照しない。

import * as p from "@clack/prompts";
import pc from "picocolors";
import { ApiClient, ApiError } from "../services/api-client.js";
import { loadConfig } from "../services/config.js";
import {
  formatQualifiedName,
  selectAgentDefinition,
  shortId,
  stateBadge,
} from "../prompt/picker-utils.js";
import {
  PromptCancelled,
  promptForSchema,
} from "../prompt/schema-prompt.js";
import type { Value } from "../types.js";

export type RunOptions = {
  qualifiedName?: string;
  project?: string;
  snapshot?: string;
  args?: string;
  wait?: boolean;
};

export async function runCmd(opts: RunOptions): Promise<void> {
  p.intro(pc.bgCyan(pc.black(" katari run ")));

  const { config } = await loadConfig();
  const projectName = opts.project ?? config.project;
  const api = new ApiClient({
    baseUrl: config.api.url,
    authToken: config.api.auth,
  });

  // Resolve project
  let projectId: string;
  try {
    const project = await api.upsertProject(projectName);
    projectId = project.id;
  } catch (err) {
    handleApiError(err);
    return;
  }

  // Fetch agent definitions for the (latest or specified) snapshot
  let definitions, snapshotId: string;
  try {
    const result = await api.listAgentDefinitions({
      projectId,
      snapshotId: opts.snapshot,
    });
    definitions = result.definitions;
    snapshotId = result.snapshotId;
  } catch (err) {
    handleApiError(err);
    return;
  }

  if (definitions.length === 0) {
    p.cancel(
      `Snapshot #${shortId(snapshotId)} has no agent definitions. ` +
        "Did you run `katari apply` first?",
    );
    process.exit(1);
  }

  // Resolve target agent
  let targetQname = opts.qualifiedName;
  let targetDef;
  if (targetQname !== undefined) {
    targetDef = definitions.find(
      (d) => formatQualifiedName(d.qualifiedName) === targetQname,
    );
    if (targetDef === undefined) {
      p.cancel(
        `Unknown agent '${targetQname}'. Available: ${
          definitions.map((d) => formatQualifiedName(d.qualifiedName)).join(", ")
        }`,
      );
      process.exit(1);
    }
  } else {
    try {
      targetDef = await selectAgentDefinition(
        definitions,
        `Run which agent? ${pc.dim(`(snapshot #${shortId(snapshotId)})`)}`,
      );
      targetQname = formatQualifiedName(targetDef.qualifiedName);
    } catch (err) {
      if (err instanceof PromptCancelled) {
        p.cancel("cancelled");
        process.exit(130);
      }
      throw err;
    }
  }

  // Resolve args
  let args: Record<string, Value>;
  if (opts.args !== undefined) {
    try {
      args = JSON.parse(opts.args);
    } catch (err) {
      p.cancel(
        `--args must be valid JSON: ${err instanceof Error ? err.message : String(err)}`,
      );
      process.exit(1);
    }
  } else {
    try {
      args = await promptArgsFromSchema(targetDef.parameters);
    } catch (err) {
      if (err instanceof PromptCancelled) {
        p.cancel("cancelled");
        process.exit(130);
      }
      throw err;
    }
  }

  // Start the agent
  const startSpinner = p.spinner();
  startSpinner.start(`Starting ${pc.cyan(targetQname)}`);
  let agentId: string;
  try {
    const result = await api.startAgent({
      projectId,
      snapshotId,
      qualifiedName: targetQname,
      args,
    });
    agentId = result.agentId;
    startSpinner.stop(
      `${pc.green("✓")} Started ${pc.cyan(targetQname)} ${pc.dim(`#${shortId(agentId)}`)}`,
    );
  } catch (err) {
    startSpinner.stop(pc.red("Start failed"), 1);
    handleApiError(err);
    return;
  }

  // Optionally wait for completion
  if (opts.wait) {
    await waitForCompletion(api, agentId);
  } else {
    p.outro(`agentId: ${agentId}`);
  }
}

/**
 * Top-level args for an agent are an object schema (= keyword arguments).
 * Unwrap it so each property becomes one prompt at the top level instead
 * of asking "include optional field" for the whole envelope.
 */
async function promptArgsFromSchema(
  schema: unknown,
): Promise<Record<string, Value>> {
  if (
    typeof schema === "object" &&
    schema !== null &&
    "type" in schema &&
    (schema as { type?: unknown }).type === "object"
  ) {
    const v = await promptForSchema(schema, { label: "args" });
    if (v.kind === "tagged") {
      return v.fields;
    }
  }
  // Fallback: schema-less / non-object → no args.
  return {};
}

async function waitForCompletion(
  api: ApiClient,
  agentId: string,
): Promise<void> {
  const spinner = p.spinner();
  spinner.start("Waiting for completion");
  let last = "running";
  while (true) {
    let row;
    try {
      row = await api.getAgent(agentId);
    } catch (err) {
      spinner.stop(pc.red("poll failed"), 1);
      handleApiError(err);
      return;
    }
    if (row.state !== last) {
      spinner.message(`state: ${stateBadge(row.state)}`);
      last = row.state;
    }
    if (
      row.state === "succeeded" ||
      row.state === "cancelled" ||
      row.state === "error"
    ) {
      spinner.stop(`finished: ${stateBadge(row.state)}`);
      if (row.state === "succeeded" && row.result !== undefined) {
        p.note(JSON.stringify(row.result, null, 2), "result");
      }
      if (row.state === "error" && row.errorMessage !== undefined) {
        p.note(row.errorMessage, "error");
      }
      p.outro(`agentId: ${agentId}`);
      return;
    }
    await sleep(500);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function handleApiError(err: unknown): never {
  if (err instanceof ApiError) {
    p.cancel(`${err.message} (HTTP ${err.status})`);
  } else {
    p.cancel(err instanceof Error ? err.message : String(err));
  }
  process.exit(1);
}
