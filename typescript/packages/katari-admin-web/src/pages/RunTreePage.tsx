import { useQuery } from "@tanstack/react-query";
import { Link, useParams } from "react-router-dom";
import { ArrowLeft } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { Card, CardContent } from "@/components/ui/Card";
import { DelegationTreeGraph } from "@/components/domain/DelegationTreeGraph";
import { RunStatusBadge, isTerminalState } from "@/components/domain/RunStatusBadge";
import type { ProjectId, RunId } from "@/api/types";

const POLL_MS = 3_000;

export function RunTreePage() {
  const { projectId, runId } = useParams<{
    projectId: string;
    runId: string;
  }>();
  const client = useApiClient();
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["run-tree", runId],
    queryFn: () =>
      client.getRunTree(projectId as ProjectId, runId as RunId),
    enabled: typeof projectId === "string" && typeof runId === "string",
    // Poll while the root is live so child delegation events (= ext
    // calls etc.) show up as they happen. Stop once the run reaches a
    // terminal state because no new nodes can appear after that.
    refetchInterval: (query) => {
      const root = query.state.data?.tree.root;
      if (root === undefined) return POLL_MS;
      return isTerminalState(root.state) ? false : POLL_MS;
    },
  });

  const root = data?.tree.root;

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex items-center gap-3">
            <Link
              to={`/project/${projectId}/runs/${runId}`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Back to run</span>
            </Link>
            <span className="text-subtle-foreground text-sm">/</span>
            <span className="font-mono text-base text-foreground">
              {root?.name ?? root?.qualifiedName ?? "Tree"}
            </span>
            {root !== undefined && <RunStatusBadge state={root.state} />}
          </span>
        }
        description="Live delegation tree. Each node represents one in-flight call; terminal calls disappear."
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load tree."}
          </p>
        )}
        {root !== undefined && (
          <Card>
            <CardContent className="overflow-auto">
              <DelegationTreeGraph root={root} />
            </CardContent>
          </Card>
        )}
      </PageContent>
    </div>
  );
}
