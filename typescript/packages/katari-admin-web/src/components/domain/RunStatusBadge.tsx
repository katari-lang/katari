import type { RunState } from "@/api/types";
import { Badge } from "@/components/ui/Badge";

const labels: Record<
  RunState,
  { tone: "info" | "warning" | "neutral" | "success" | "danger"; label: string }
> = {
  running: { tone: "info", label: "running" },
  cancelling: { tone: "warning", label: "cancelling" },
  done: { tone: "success", label: "done" },
  error: { tone: "danger", label: "error" },
};

export function RunStatusBadge({
  state,
  cancelReason,
}: {
  state: RunState;
  cancelReason?: "user" | "error" | null;
}) {
  // A user-initiated cancel ends as `error` (the 4-state model has no distinct
  // `cancelled`); show it as "cancelled" so the operator isn't told it failed.
  if (state === "error" && cancelReason === "user") {
    return <Badge tone="neutral">cancelled</Badge>;
  }
  const { tone, label } = labels[state];
  return <Badge tone={tone}>{label}</Badge>;
}

export function isTerminalState(state: RunState): boolean {
  return state === "done" || state === "error";
}
