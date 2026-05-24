import { Badge } from "@/components/ui/Badge";
import type { AgentState } from "@/api/types";

const labels: Record<AgentState, { tone: "info" | "warning" | "neutral" | "success" | "danger"; label: string }> = {
  running: { tone: "info", label: "running" },
  cancelling: { tone: "warning", label: "cancelling" },
  cancelled: { tone: "neutral", label: "cancelled" },
  succeeded: { tone: "success", label: "succeeded" },
  error: { tone: "danger", label: "error" },
};

export function AgentStatusBadge({ state }: { state: AgentState }) {
  const { tone, label } = labels[state];
  return <Badge tone={tone}>{label}</Badge>;
}

export function isTerminalState(state: AgentState): boolean {
  return state === "cancelled" || state === "succeeded" || state === "error";
}
