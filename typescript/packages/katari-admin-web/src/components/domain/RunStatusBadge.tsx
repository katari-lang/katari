import type { RunState } from "@/api/types";
import { Badge } from "@/components/ui/Badge";

const labels: Record<
  RunState,
  { tone: "info" | "warning" | "neutral" | "success" | "danger"; label: string }
> = {
  running: { tone: "info", label: "running" },
  cancelling: { tone: "warning", label: "cancelling" },
  cancelled: { tone: "neutral", label: "cancelled" },
  succeeded: { tone: "success", label: "succeeded" },
  error: { tone: "danger", label: "error" },
};

export function RunStatusBadge({ state }: { state: RunState }) {
  const { tone, label } = labels[state];
  return <Badge tone={tone}>{label}</Badge>;
}

export function isTerminalState(state: RunState): boolean {
  return state === "cancelled" || state === "succeeded" || state === "error";
}
