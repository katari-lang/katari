import { useMemo } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Boxes } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { AgentsSnapshotPicker } from "@/components/domain/AgentsSnapshotPicker";
import { AgentsTree } from "@/components/domain/AgentsTree";
import type { ProjectId, SnapshotId } from "@/api/types";

export function AgentsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const [params, setParams] = useSearchParams();
  const client = useApiClient();

  const snapshotParam = params.get("snapshot");
  const selected: SnapshotId | null =
    snapshotParam === null || snapshotParam === "latest"
      ? null
      : (snapshotParam as SnapshotId);

  // Project name is used as a qualified-name prefix filter so the tree
  // defaults to "what this project actually defines". stdlib (`prim.*`)
  // and library entries flow through the same schema bundle now (= the
  // compiler emits everything uniformly), so admin has to do the
  // display-time filtering itself.
  const projectQ = useQuery({
    queryKey: ["project", projectId],
    queryFn: () => client.getProject(projectId as ProjectId),
    enabled: typeof projectId === "string",
  });
  const projectName = projectQ.data?.project.name;

  // Persist the "show stdlib & libraries" toggle in the URL so refreshes
  // and shared links keep the same view. Truthy values that count as
  // "on": `?showAll=1` / `?showAll=true`. Anything else is off.
  const showAllParam = params.get("showAll");
  const showAll = showAllParam === "1" || showAllParam === "true";

  function setShowAll(next: boolean) {
    if (next) params.set("showAll", "1");
    else params.delete("showAll");
    setParams(params);
  }

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["agents", projectId, selected ?? "latest"],
    queryFn: () =>
      client.listAgents({
        projectId: projectId as ProjectId,
        snapshotId: selected ?? undefined,
      }),
    enabled: typeof projectId === "string",
  });

  const visibleAgents = useMemo(() => {
    if (data === undefined) return [];
    if (showAll || projectName === undefined) return data.agents;
    const prefix = `${projectName}.`;
    return data.agents.filter((a) => a.qualifiedName.startsWith(prefix));
  }, [data, showAll, projectName]);

  function setSelected(next: SnapshotId | null) {
    if (next === null) {
      params.delete("snapshot");
    } else {
      params.set("snapshot", next);
    }
    setParams(params);
  }

  const hiddenCount =
    data === undefined ? 0 : data.agents.length - visibleAgents.length;

  return (
    <div>
      <PageHeader
        title="Agents"
        description="Callable agents in the selected snapshot"
        docs={{ slug: "concepts/agents", title: "About agents" }}
      />
      <PageContent>
        {typeof projectId === "string" && (
          <div className="mb-4 flex flex-wrap items-center gap-2">
            <AgentsSnapshotPicker
              projectId={projectId as ProjectId}
              selected={selected}
              resolvedId={data?.snapshotId ?? null}
              onSelect={setSelected}
            />
            <label className="inline-flex cursor-pointer items-center gap-2 bg-transparent px-3 py-1.5 text-xs transition-colors text-muted-foreground">
              <input
                type="checkbox"
                checked={showAll}
                onChange={(e) => setShowAll(e.target.checked)}
                className="accent-accent cursor-pointer bg-background transition-all"
              />
              <span>Show stdlib &amp; libraries</span>
            </label>
          </div>
        )}
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load agents."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {visibleAgents.length === 0 ? (
              <EmptyState
                icon={Boxes}
                title={
                  data.agents.length === 0
                    ? "No agents in this snapshot"
                    : "Only stdlib and libraries here"
                }
                description={
                  data.agents.length === 0
                    ? "Declare an agent and re-run katari apply."
                    : `Toggle "Show stdlib & libraries" to reveal ${data.agents.length} entries from other packages.`
                }
              />
            ) : (
              <div className="border border-border">
                <AgentsTree
                  agents={visibleAgents}
                  href={(agent) => {
                    const search =
                      selected === null ? "" : `?snapshot=${selected}`;
                    return `/project/${projectId}/agents/${encodeURIComponent(
                      agent.qualifiedName,
                    )}${search}`;
                  }}
                />
              </div>
            )}
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}
