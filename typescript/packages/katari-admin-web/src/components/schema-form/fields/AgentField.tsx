// Form field for an agent-typed (`$agent`) argument. The value it produces is
// the callable-reference envelope `{$agent: "qualified.name@snapshot"}` — the
// EXTERNAL form the runtime dispatches by. The operator picks an agent from the
// form's snapshot; the snapshot stamp is built here (the "front-end builds
// qualified.name@snapshot" half of the two stamping sites). Closures are not
// selectable (they have no top-level name).

import { useQuery } from "@tanstack/react-query";
import { Bot } from "lucide-react";
import type { ProjectId } from "@/api/types";
import { SelectMenu } from "@/components/ui/SelectMenu";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { useCurrentProjectId } from "@/lib/useCurrentProjectId";
import { useSchemaFormContext } from "../context";

/** Extract the bare qualified name from a `{$agent: "qname@snapshot"}` value. */
function currentQname(value: unknown): string | null {
  if (value === null || typeof value !== "object") return null;
  const agent = (value as Record<string, unknown>).$agent;
  if (typeof agent !== "string") return null;
  const at = agent.indexOf("@");
  return at >= 0 ? agent.slice(0, at) : agent;
}

export function AgentField({
  value,
  onChange,
}: {
  value: unknown;
  onChange: (v: unknown) => void;
}) {
  const projectId = useCurrentProjectId();
  const { snapshotId } = useSchemaFormContext();
  const client = useApiClient();

  const agentsQ = useQuery({
    queryKey: ["agents", projectId, snapshotId ?? "latest"],
    queryFn: () => client.listAgents({ projectId: projectId as ProjectId, snapshotId }),
    enabled: projectId !== null,
  });

  if (projectId === null) {
    return (
      <p className="border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-warning">
        Agent selection requires a project context.
      </p>
    );
  }

  const agents = agentsQ.data?.agents ?? [];
  // Build the external id off the RESOLVED snapshot the agents were listed
  // against (concrete even when the form's snapshot was "latest").
  const resolvedSnapshot = agentsQ.data?.snapshotId ?? snapshotId;
  const selected = currentQname(value);

  const options = agents.map((agent) => ({
    key: agent.qualifiedName,
    label: agent.qualifiedName,
  }));

  return (
    <div className="flex items-center gap-2">
      <Bot className="size-4 shrink-0 text-muted-foreground" />
      <div className="w-fit min-w-64">
        <SelectMenu
          value={selected ?? ""}
          options={options}
          placeholder={agentsQ.isLoading ? "Loading agents…" : "Select an agent"}
          onChange={(qname) => {
            onChange(
              resolvedSnapshot !== undefined
                ? { $agent: `${qname}@${resolvedSnapshot}` }
                : { $agent: qname },
            );
          }}
        />
      </div>
    </div>
  );
}
