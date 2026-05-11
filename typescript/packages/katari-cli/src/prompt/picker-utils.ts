// 共通のセレクタヘルパ。リッチな表示 (起動時刻 / qualifiedName / args summary
// など) を 1 箇所に集めて、各 command が使い回す。

import * as p from "@clack/prompts";
import pc from "picocolors";
import type {
  AgentRow,
  ApiPendingEscalation,
  Project,
  SnapshotSummary,
} from "../services/api-client.js";
import type { AgentDefinition, RawValue } from "katari-runtime";
import { PromptCancelled } from "./schema-prompt.js";

/** ISO timestamp → "2 hours ago" 風表示。 */
export function relativeTime(iso: string, now: Date = new Date()): string {
  const t = new Date(iso).getTime();
  const diff = now.getTime() - t;
  const sec = Math.floor(diff / 1000);
  if (sec < 60) return `${sec}s ago`;
  const min = Math.floor(sec / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return `${day}d ago`;
}

/** UUID の短縮表示 (先頭 8 文字)。 */
export function shortId(id: string): string {
  return id.slice(0, 8);
}

/** Value を 1 行の human readable な表示に。 */
export function summarizeValue(v: RawValue, maxLen = 30): string {
  let s: string;
  if (v === null) {
    s = "null";
  } else if (typeof v === "string") {
    s = JSON.stringify(v);
  } else if (typeof v === "number") {
    s = String(v);
  } else if (typeof v === "boolean") {
    s = String(v);
  } else if (Array.isArray(v)) {
    s = `[${v.length} items]`;
  } else if (typeof v === "object") {
    if ("$callable" in v && typeof v.$callable === "string") {
      s = `<callable ${v.$callable}>`;
    } else if ("$ctor" in v && typeof v.$ctor === "string") {
      const fields = Object.keys(v).filter((k) => k !== "$ctor");
      s = `${v.$ctor}{${fields.join(",")}}`;
    } else {
      s = `{${Object.keys(v).join(",")}}`;
    }
  } else {
    s = String(v);
  }
  return s.length > maxLen ? s.slice(0, maxLen - 1) + "…" : s;
}

export function summarizeArgs(args: Record<string, RawValue>, maxLen = 40): string {
  const parts = Object.entries(args).map(
    ([k, v]) => `${k}=${summarizeValue(v, 20)}`,
  );
  const joined = parts.join(", ");
  return joined.length > maxLen ? joined.slice(0, maxLen - 1) + "…" : joined;
}

// ─── Selectors ─────────────────────────────────────────────────────────────

export async function selectAgentDefinition(
  defs: AgentDefinition[],
  message = "Select an agent",
): Promise<AgentDefinition> {
  if (defs.length === 0) {
    p.cancel("No agent definitions in the latest snapshot.");
    throw new PromptCancelled();
  }
  const choice = await p.select({
    message,
    options: defs.map((d) => ({
      value: d,
      label: formatQualifiedName(d.qualifiedName),
      hint: d.description,
    })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as AgentDefinition;
}

export async function selectAgent(
  agents: AgentRow[],
  message: string,
): Promise<AgentRow> {
  if (agents.length === 0) {
    p.cancel(pc.yellow("No agents to choose from."));
    throw new PromptCancelled();
  }
  const choice = await p.select({
    message,
    options: agents.map((a) => ({
      value: a,
      label: `${pc.cyan(a.qualifiedName)} ${pc.dim(`#${shortId(a.id)}`)} ${stateBadge(a.state)}`,
      hint:
        `started ${relativeTime(a.createdAt)}` +
        (Object.keys(a.args).length > 0 ? ` · args: ${summarizeArgs(a.args)}` : ""),
    })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as AgentRow;
}

export async function selectSnapshot(
  snapshots: SnapshotSummary[],
  message = "Select a snapshot",
): Promise<SnapshotSummary> {
  if (snapshots.length === 0) {
    p.cancel(pc.yellow("No snapshots."));
    throw new PromptCancelled();
  }
  const choice = await p.select({
    message,
    options: snapshots.map((s) => ({
      value: s,
      label: pc.cyan(`#${shortId(s.id)}`),
      hint: `created ${relativeTime(s.createdAt)}`,
    })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as SnapshotSummary;
}

export async function selectProject(
  projects: Project[],
  message = "Select a project",
): Promise<Project> {
  if (projects.length === 0) {
    p.cancel(pc.yellow("No projects."));
    throw new PromptCancelled();
  }
  const choice = await p.select({
    message,
    options: projects.map((proj) => ({
      value: proj,
      label: pc.cyan(proj.name),
      hint: `#${shortId(proj.id)} · created ${relativeTime(proj.createdAt)}`,
    })),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as Project;
}

export async function selectEscalation(
  escalations: ApiPendingEscalation[],
  agentByDelegationId: Map<string, AgentRow>,
  message = "Select an escalation",
): Promise<ApiPendingEscalation> {
  if (escalations.length === 0) {
    p.cancel(pc.yellow("No pending escalations."));
    throw new PromptCancelled();
  }
  const choice = await p.select({
    message,
    options: escalations.map((e) => {
      const agent = agentByDelegationId.get(e.delegationId);
      const fromAgent = agent !== undefined
        ? `from ${pc.cyan(agent.qualifiedName)} ${pc.dim(`#${shortId(agent.id)}`)}`
        : pc.dim(`from delegation #${shortId(e.delegationId)}`);
      const askSummary = summarizeAgentDefId(e.agentDefId);
      return {
        value: e,
        label: `${askSummary} ${fromAgent}`,
        hint:
          `opened ${relativeTime(e.createdAt)}` +
          (Object.keys(e.args).length > 0 ? ` · args: ${summarizeArgs(e.args)}` : ""),
      };
    }),
  });
  if (p.isCancel(choice)) throw new PromptCancelled();
  return choice as ApiPendingEscalation;
}

// ─── Formatters ────────────────────────────────────────────────────────────

/** 'QualifiedName' is already a flat dotted string; this helper exists
 * for call-site clarity (and is a no-op now). */
export function formatQualifiedName(qn: string): string {
  return qn;
}

export function stateBadge(state: AgentRow["state"]): string {
  switch (state) {
    case "running":
      return pc.yellow("● running");
    case "cancelling":
      return pc.yellow("◐ cancelling");
    case "cancelled":
      return pc.dim("○ cancelled");
    case "succeeded":
      return pc.green("✓ succeeded");
    case "error":
      return pc.red("✗ error");
  }
}

export function summarizeAgentDefId(id: unknown): string {
  if (typeof id === "object" && id !== null && "kind" in id) {
    const decoded = id as { kind: string; value: unknown };
    if (decoded.kind === "qname" && typeof decoded.value === "string") {
      return formatQualifiedName(decoded.value);
    }
    if (decoded.kind === "closure") {
      return pc.dim(`<closure ${decoded.value}>`);
    }
  }
  return pc.dim("<opaque>");
}

