import type { RunState } from "../../api/types";
import { Badge, type BadgeTone } from "../ui/Badge";
import { Spinner } from "../ui/Spinner";

const tones: Record<RunState, BadgeTone> = {
  running: "info",
  cancelling: "warning",
  done: "success",
  error: "danger",
  cancelled: "neutral",
};

export function RunStateBadge({ state }: { state: RunState }) {
  return (
    <Badge tone={tones[state]}>
      {(state === "running" || state === "cancelling") && <Spinner className="size-3" />}
      {state}
    </Badge>
  );
}
