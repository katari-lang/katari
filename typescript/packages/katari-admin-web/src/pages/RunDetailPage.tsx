import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { ArrowLeft, Ban } from "lucide-react";
import { useState } from "react";
import toast from "react-hot-toast";
import { Link, useParams } from "react-router-dom";
import type { EscalationState, ProjectId, RunId } from "@/api/types";
import { isTerminalState, RunStatusBadge } from "@/components/domain/RunStatusBadge";
import { RunTreeGraph } from "@/components/domain/RunTreeGraph";
import { ValueViewer } from "@/components/domain/ValueViewer";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { CopyableId } from "@/components/ui/CopyableId";
import { CopyButton } from "@/components/ui/CopyButton";
import { Dialog, DialogFooter } from "@/components/ui/Dialog";
import { MetadataRow } from "@/components/ui/MetadataRow";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { useSnapshotMessage } from "@/hooks/useSnapshotMessage";
import { formatDateTime, relativeTime } from "@/lib/format";

const POLL_MS = 3_000;

const escalationTones: Record<EscalationState, "info" | "success"> = {
  open: "info",
  answered: "success",
};

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
      query.state.data !== undefined && !isTerminalState(query.state.data.run.state)
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
      toast.error(err instanceof Error ? err.message : "Cancel failed");
    },
  });

  const [cancelDialogOpen, setCancelDialogOpen] = useState(false);

  const run = data?.run;
  const canCancel = run !== undefined && (run.state === "running" || run.state === "cancelling");
  const isLive = run !== undefined && !isTerminalState(run.state);

  const { getMessage } = useSnapshotMessage(projectId);
  const snapshotMessage = getMessage(run?.snapshotId);

  // Live tree polling. Only fires while the run is in flight — once the
  // run reaches a terminal state, the tree has been deleted by the
  // engine (= live `delegations` rows DROP on terminal ack), so polling
  // would just return an empty tree.
  const treeQ = useQuery({
    queryKey: ["run-tree", runId],
    queryFn: () => client.getRunTree(projectId as ProjectId, runId as RunId),
    enabled: typeof projectId === "string" && typeof runId === "string" && isLive,
    refetchInterval: (query) => {
      const root = query.state.data?.tree.root;
      if (root === undefined) return POLL_MS;
      return isTerminalState(root.state) ? false : POLL_MS;
    },
  });

  // Escalations for this run, filtered server-side by runId.
  const escalationsQ = useQuery({
    queryKey: ["escalations", projectId, runId, "run-detail"],
    queryFn: () =>
      client.listEscalations({
        projectId: projectId as ProjectId,
        runId: runId as RunId,
      }),
    enabled: typeof projectId === "string" && typeof runId === "string",
    refetchInterval: isLive ? POLL_MS : false,
  });

  const runEscalations = escalationsQ.data?.escalations ?? [];

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
            <span className="text-base text-foreground">{run?.name ?? runId}</span>
            {run !== undefined && (
              <RunStatusBadge state={run.state} cancelReason={run.cancelReason} />
            )}
          </span>
        }
        actions={
          canCancel ? (
            <Button
              variant="danger"
              onClick={() => setCancelDialogOpen(true)}
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
            className="flex flex-col gap-4"
          >
            {/* Metadata + Arguments */}
            <div className="grid gap-4 lg:grid-cols-3">
              <Card className="lg:col-span-2">
                <CardHeader>
                  <CardTitle>Arguments</CardTitle>
                </CardHeader>
                <CardContent>
                  <div className="mb-1">
                    <CopyButton text={JSON.stringify(run.args, null, 2)} label="Copied JSON">
                      Copy JSON
                    </CopyButton>
                  </div>
                  <ValueViewer value={run.args} projectId={projectId} />
                </CardContent>
              </Card>
              <Card>
                <CardHeader>
                  <CardTitle>Metadata</CardTitle>
                </CardHeader>
                <CardContent>
                  <dl className="space-y-2 text-sm">
                    <MetadataRow label="ID" value={<CopyableId value={run.id} />} />
                    <MetadataRow
                      label="Name"
                      value={<span className="text-foreground">{run.name}</span>}
                    />
                    <MetadataRow
                      label="Agent"
                      value={
                        <Link
                          to={`/project/${projectId}/agents/${encodeURIComponent(
                            run.qualifiedName,
                          )}?snapshot=${run.snapshotId}`}
                          className="font-mono text-xs text-foreground hover:underline"
                        >
                          {run.qualifiedName}
                        </Link>
                      }
                    />
                    <MetadataRow
                      label="Snapshot"
                      value={
                        <span className="flex items-center gap-2">
                          <Link
                            to={`/project/${projectId}/agents?snapshot=${run.snapshotId}`}
                            className="text-foreground hover:underline"
                          >
                            {snapshotMessage ?? "—"}
                          </Link>
                        </span>
                      }
                    />
                    <MetadataRow label="Started" value={formatDateTime(run.createdAt)} />
                    <MetadataRow label="Updated" value={formatDateTime(run.updatedAt)} />
                    {run.cancelReason !== null && (
                      <MetadataRow
                        label="Cancel reason"
                        value={
                          <span className="text-foreground">
                            {run.cancelReason === "user" ? "user-initiated" : "child error"}
                          </span>
                        }
                      />
                    )}
                  </dl>
                </CardContent>
              </Card>
            </div>

            {/* Escalations + Tree/Result side by side */}
            <div className="grid gap-4 lg:grid-cols-[minmax(200px,1fr)_2fr] items-start">
              {/* Escalations (compact list) */}
              <Card>
                <CardHeader>
                  <div className="flex items-center gap-2">
                    <CardTitle>Escalations</CardTitle>
                    <Badge tone="neutral">{runEscalations.length}</Badge>
                  </div>
                </CardHeader>
                <CardContent>
                  {escalationsQ.isLoading ? (
                    <p className="text-sm text-subtle-foreground">Loading…</p>
                  ) : runEscalations.length === 0 ? (
                    <p className="text-sm text-subtle-foreground">No escalations.</p>
                  ) : (
                    <ul className="space-y-1">
                      {runEscalations.map((esc) => (
                        <li key={esc.escalationId} className="px-2 py-1.5 hover:bg-muted">
                          <Link
                            to={`/project/${projectId}/escalations/${esc.escalationId}`}
                            className="flex items-center gap-2"
                          >
                            <Badge tone={escalationTones[esc.state]}>{esc.state}</Badge>
                            <span className="flex-1 truncate font-mono text-xs text-foreground">
                              {esc.agentDefId}
                            </span>
                            <span
                              className="text-xs text-subtle-foreground"
                              title={formatDateTime(esc.createdAt)}
                            >
                              {relativeTime(esc.createdAt)}
                            </span>
                          </Link>
                        </li>
                      ))}
                    </ul>
                  )}
                </CardContent>
              </Card>

              {/* Tree / Result (wide column) */}
              <div className="flex flex-col gap-4">
                {isLive && (
                  <div>
                    <h3 className="mb-2 text-sm font-medium text-foreground">Delegation tree</h3>
                    {treeQ.data !== undefined ? (
                      <RunTreeGraph root={treeQ.data.tree.root} />
                    ) : treeQ.isLoading ? (
                      <p className="text-sm text-subtle-foreground">Loading…</p>
                    ) : (
                      <p className="text-sm text-subtle-foreground">No live delegations.</p>
                    )}
                  </div>
                )}

                {!isLive && run.result !== undefined && (
                  <Card>
                    <CardHeader>
                      <CardTitle>Result</CardTitle>
                    </CardHeader>
                    <CardContent>
                      <div className="mb-1">
                        <CopyButton text={JSON.stringify(run.result, null, 2)} label="Copied JSON">
                          Copy JSON
                        </CopyButton>
                      </div>
                      <ValueViewer value={run.result} projectId={projectId} />
                    </CardContent>
                  </Card>
                )}
              </div>
            </div>

            {/* Error */}
            {run.errorMessage !== undefined && run.errorMessage !== "" && (
              <Card className="border-danger/30">
                <CardHeader>
                  <CardTitle className="text-danger">Error</CardTitle>
                </CardHeader>
                <CardContent>
                  <pre className="overflow-auto border border-danger/30 bg-danger/5 p-3 text-xs text-danger">
                    {run.errorMessage}
                  </pre>
                </CardContent>
              </Card>
            )}
          </motion.div>
        )}
      </PageContent>
      <Dialog
        open={cancelDialogOpen}
        onClose={() => setCancelDialogOpen(false)}
        title="Cancel run"
        description="This will kill all child delegations. This action cannot be undone."
        size="sm"
      >
        <p className="text-sm text-foreground">
          Are you sure you want to cancel <code className="font-mono">{run?.name ?? runId}</code>?
        </p>
        <DialogFooter>
          <Button variant="secondary" onClick={() => setCancelDialogOpen(false)}>
            Keep running
          </Button>
          <Button
            variant="danger"
            loading={cancel.isPending}
            onClick={() => {
              cancel.mutate(undefined, {
                onSettled: () => setCancelDialogOpen(false),
              });
            }}
          >
            Cancel run
          </Button>
        </DialogFooter>
      </Dialog>
    </div>
  );
}
