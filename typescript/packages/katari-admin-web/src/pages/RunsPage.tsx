import { Link, useNavigate, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Activity, ArrowRight } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { Button } from "@/components/ui/Button";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import {
  RunStatusBadge,
  isTerminalState,
} from "@/components/domain/RunStatusBadge";
import { formatDateTime, relativeTime } from "@/lib/format";
import type { ProjectId } from "@/api/types";

const POLL_MS = 3_000;

export function RunsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const client = useApiClient();
  const navigate = useNavigate();
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["runs", projectId],
    queryFn: () =>
      client.listRuns({ projectId: projectId as ProjectId, limit: 200 }),
    enabled: typeof projectId === "string",
    refetchInterval: (query) => {
      const rows = query.state.data?.runs ?? [];
      const anyLive = rows.some((r) => !isTerminalState(r.state));
      return anyLive ? POLL_MS : false;
    },
  });

  // Snapshot summary lookup so the table can show the commit-message-like
  // `message` instead of a shortened UUID. Cache is shared with the
  // snapshot picker on /agents.
  const snapshotsQ = useQuery({
    queryKey: ["snapshots", projectId],
    queryFn: () =>
      client.listSnapshots(projectId as ProjectId, { limit: 200 }),
    enabled: typeof projectId === "string",
  });
  const snapshotMessageById = new Map(
    (snapshotsQ.data?.snapshots ?? []).map((s) => [s.id, s.message]),
  );

  return (
    <div>
      <PageHeader
        title="Runs"
        description="Operator-launched runs"
        docs={{ slug: "concepts/runs", title: "About runs" }}
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load runs."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {data.runs.length === 0 ? (
              <EmptyState
                icon={Activity}
                title="No runs yet"
                description="Pick an agent to invoke and the run will land here."
                action={
                  <Link to={`/project/${projectId}/agents`}>
                    <Button variant="primary" size="sm">
                      Browse agents
                      <ArrowRight className="size-3.5" />
                    </Button>
                  </Link>
                }
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>State</TH>
                    <TH>Run</TH>
                    <TH>Agent</TH>
                    <TH>Snapshot</TH>
                    <TH>Created</TH>
                    <TH>Updated</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.runs.map((run) => (
                    <TR
                      key={run.id}
                      className="cursor-pointer h-16"
                      onClick={() =>
                        navigate(`/project/${projectId}/runs/${run.id}`)
                      }
                    >
                      <TD>
                        <RunStatusBadge state={run.state} />
                      </TD>
                      <TD>
                        <Link
                          to={`/project/${projectId}/runs/${run.id}`}
                          className="block hover:underline"
                          onClick={(e) => e.stopPropagation()}
                        >
                          <div className="font-medium text-foreground">
                            {run.name}
                          </div>
                        </Link>
                      </TD>
                      <TD className="font-mono text-xs text-muted-foreground">
                        {run.qualifiedName}
                      </TD>
                      <TD className="text-xs text-muted-foreground">
                        <Link
                          to={`/project/${projectId}/agents?snapshot=${run.snapshotId}`}
                          className="hover:underline hover:text-foreground"
                          onClick={(e) => e.stopPropagation()}
                        >
                          {snapshotMessageById.get(run.snapshotId) ?? "—"}
                        </Link>
                      </TD>
                      <TD
                        className="text-xs text-muted-foreground"
                        title={formatDateTime(run.createdAt)}
                      >
                        {relativeTime(run.createdAt)}
                      </TD>
                      <TD
                        className="text-xs text-muted-foreground"
                        title={formatDateTime(run.updatedAt)}
                      >
                        {relativeTime(run.updatedAt)}
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </Table>
            )}
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}
