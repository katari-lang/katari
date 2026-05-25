import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "react-router-dom";
import { motion } from "framer-motion";
import { ArrowLeft, Ban } from "lucide-react";
import toast from "react-hot-toast";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import {
  RunStatusBadge,
  isTerminalState,
} from "@/components/domain/RunStatusBadge";
import { DelegationTreeGraph } from "@/components/domain/DelegationTreeGraph";
import { ValueViewer } from "@/components/domain/ValueViewer";
import { formatDateTime } from "@/lib/format";
import type { ProjectId, RunId } from "@/api/types";

const POLL_MS = 3_000;

export function RunDetailPage() {
  const { projectId, runId } = useParams<{
    projectId: string;
    runId: string;
  }>();
  const client = useApiClient();
  const queryClient = useQueryClient();

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["run", runId],
    queryFn: () => client.getRun(projectId as ProjectId, runId as RunId),
    enabled: typeof projectId === "string" && typeof runId === "string",
    refetchInterval: (query) =>
      query.state.data !== undefined &&
      !isTerminalState(query.state.data.run.state)
        ? POLL_MS
        : false,
  });

  const cancel = useMutation({
    mutationFn: () => client.cancelRun(projectId as ProjectId, runId as RunId),
    onSuccess: () => {
      toast.success("Cancel requested");
      void queryClient.invalidateQueries({ queryKey: ["run", runId] });
      void queryClient.invalidateQueries({ queryKey: ["runs", projectId] });
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed to cancel.");
    },
  });

  const run = data?.run;
  const canCancel =
    run !== undefined &&
    (run.state === "running" || run.state === "cancelling");
  const isLive = run !== undefined && !isTerminalState(run.state);

  // Live tree polling. Only fires while the run is in flight — once the
  // run reaches a terminal state, the tree has been deleted by the
  // engine (= live `delegations` rows DROP on terminal ack), so polling
  // would just return an empty tree.
  const treeQ = useQuery({
    queryKey: ["run-tree", runId],
    queryFn: () =>
      client.getRunTree(projectId as ProjectId, runId as RunId),
    enabled: typeof projectId === "string" && typeof runId === "string" && isLive,
    refetchInterval: (query) => {
      const root = query.state.data?.tree.root;
      if (root === undefined) return POLL_MS;
      return isTerminalState(root.state) ? false : POLL_MS;
    },
  });

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex items-center gap-3">
            <Link
              to={`/project/${projectId}/runs`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Runs</span>
            </Link>
            <span className="text-subtle-foreground text-sm">/</span>
            <span className="font-mono text-base text-foreground">
              {run?.name ?? runId}
            </span>
            {run !== undefined && <RunStatusBadge state={run.state} />}
          </span>
        }
        actions={
          canCancel ? (
            <Button
              variant="danger"
              onClick={() => cancel.mutate()}
              loading={cancel.isPending}
            >
              <Ban className="size-4" />
              Cancel
            </Button>
          ) : null
        }
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load run."}
          </p>
        )}
        {run !== undefined && (
          <motion.div
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.2 }}
            className="grid gap-4 lg:grid-cols-3"
          >
            <Card className="lg:col-span-2">
              <CardHeader>
                <CardTitle>Arguments</CardTitle>
              </CardHeader>
              <CardContent>
                <ValueViewer value={run.args} />
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Metadata</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="space-y-2 text-sm">
                  <Row
                    label="Run ID"
                    value={
                      <code className="font-mono text-xs">{run.id}</code>
                    }
                  />
                  <Row
                    label="Name"
                    value={
                      <span className="text-foreground">{run.name}</span>
                    }
                  />
                  <Row
                    label="Agent"
                    value={
                      <code className="font-mono text-xs">
                        {run.qualifiedName}
                      </code>
                    }
                  />
                  <Row
                    label="Snapshot"
                    value={
                      <code className="font-mono text-xs">
                        {run.snapshotId}
                      </code>
                    }
                  />
                  <Row
                    label="Started"
                    value={formatDateTime(run.createdAt)}
                  />
                  <Row
                    label="Updated"
                    value={formatDateTime(run.updatedAt)}
                  />
                  {run.cancelReason !== null && (
                    <Row
                      label="Cancel reason"
                      value={
                        <span className="text-foreground">
                          {run.cancelReason === "user"
                            ? "user-initiated"
                            : "child error"}
                        </span>
                      }
                    />
                  )}
                </dl>
              </CardContent>
            </Card>
            {isLive && (
              <Card className="lg:col-span-3">
                <CardHeader>
                  <CardTitle>Delegation tree</CardTitle>
                </CardHeader>
                <CardContent>
                  {treeQ.data !== undefined ? (
                    <DelegationTreeGraph root={treeQ.data.tree.root} />
                  ) : treeQ.isLoading ? (
                    <p className="text-sm text-subtle-foreground">
                      Loading tree...
                    </p>
                  ) : (
                    <p className="text-sm text-subtle-foreground">
                      No in-flight delegations.
                    </p>
                  )}
                </CardContent>
              </Card>
            )}
            {!isLive && run.result !== undefined && (
              <Card className="lg:col-span-3">
                <CardHeader>
                  <CardTitle>Result</CardTitle>
                </CardHeader>
                <CardContent>
                  <ValueViewer value={run.result} />
                </CardContent>
              </Card>
            )}
            {run.errorMessage !== undefined && run.errorMessage !== "" && (
              <Card className="lg:col-span-3 border-danger/30">
                <CardHeader>
                  <CardTitle className="text-danger">Error</CardTitle>
                </CardHeader>
                <CardContent>
                  <pre className="overflow-auto  border border-danger/30 bg-danger/5 p-3 text-xs text-danger">
                    {run.errorMessage}
                  </pre>
                </CardContent>
              </Card>
            )}
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-[11px] uppercase tracking-wider text-subtle-foreground">
        {label}
      </dt>
      <dd className="text-right text-foreground">{value}</dd>
    </div>
  );
}
