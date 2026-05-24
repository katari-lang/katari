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
import { AgentStatusBadge, isTerminalState } from "@/components/domain/AgentStatusBadge";
import { ValueViewer } from "@/components/domain/ValueViewer";
import { formatDateTime } from "@/lib/format";
import type { AgentId } from "@/api/types";

const POLL_MS = 3_000;

export function AgentDetailPage() {
  const { projectId, agentId } = useParams<{ projectId: string; agentId: string }>();
  const client = useApiClient();
  const queryClient = useQueryClient();

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["agent", agentId],
    queryFn: () => client.getAgent(agentId as AgentId),
    enabled: typeof agentId === "string",
    refetchInterval: (query) =>
      query.state.data !== undefined && !isTerminalState(query.state.data.agent.state)
        ? POLL_MS
        : false,
  });

  const cancel = useMutation({
    mutationFn: () => client.cancelAgent(agentId as AgentId),
    onSuccess: () => {
      toast.success("Cancel requested");
      void queryClient.invalidateQueries({ queryKey: ["agent", agentId] });
      void queryClient.invalidateQueries({ queryKey: ["agents", projectId] });
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed to cancel.");
    },
  });

  const agent = data?.agent;
  const canCancel =
    agent !== undefined && (agent.state === "running" || agent.state === "cancelling");

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex items-center gap-3">
            <Link
              to={`/project/${projectId}/agents`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Agents</span>
            </Link>
            <span className="text-subtle-foreground">/</span>
            <span className="font-mono text-base">{agent?.qualifiedName ?? agentId}</span>
            {agent !== undefined && <AgentStatusBadge state={agent.state} />}
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
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load agent."}
          </p>
        )}
        {agent !== undefined && (
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
                <ValueViewer value={agent.args} />
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Metadata</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="space-y-2 text-sm">
                  <Row label="Agent ID" value={<code className="font-mono text-xs">{agent.id}</code>} />
                  <Row label="Snapshot" value={<code className="font-mono text-xs">{agent.snapshotId}</code>} />
                  <Row label="Started" value={formatDateTime(agent.createdAt)} />
                  <Row label="Updated" value={formatDateTime(agent.updatedAt)} />
                </dl>
              </CardContent>
            </Card>
            {agent.result !== undefined && (
              <Card className="lg:col-span-3">
                <CardHeader>
                  <CardTitle>Result</CardTitle>
                </CardHeader>
                <CardContent>
                  <ValueViewer value={agent.result} />
                </CardContent>
              </Card>
            )}
            {agent.errorMessage !== undefined && agent.errorMessage !== "" && (
              <Card className="lg:col-span-3 border-danger/30">
                <CardHeader>
                  <CardTitle className="text-danger">Error</CardTitle>
                </CardHeader>
                <CardContent>
                  <pre className="overflow-auto  border border-danger/30 bg-danger/5 p-3 text-xs text-danger">
                    {agent.errorMessage}
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
      <dt className="text-[11px] uppercase tracking-wider text-subtle-foreground">{label}</dt>
      <dd className="text-right text-foreground">{value}</dd>
    </div>
  );
}
