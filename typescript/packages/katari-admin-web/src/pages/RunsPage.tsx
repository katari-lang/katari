import { Link, useNavigate, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Activity } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import {
  RunStatusBadge,
  isTerminalState,
} from "@/components/domain/RunStatusBadge";
import { formatDateTime, relativeTime, shortId } from "@/lib/format";
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

  return (
    <div>
      <PageHeader
        title="Runs"
        description="Operator-launched runs, refreshed every 3s while any are live."
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
                description="Start a run from the Agents page to populate this list."
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>State</TH>
                    <TH>Run</TH>
                    <TH>Snapshot</TH>
                    <TH>Created</TH>
                    <TH>Updated</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.runs.map((run) => (
                    <TR
                      key={run.id}
                      className="cursor-pointer"
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
                          <div className="mt-0.5 font-mono text-[11px] text-subtle-foreground">
                            {run.qualifiedName} · {shortId(run.id)}
                          </div>
                        </Link>
                      </TD>
                      <TD className="font-mono text-xs text-muted-foreground">
                        {shortId(run.snapshotId)}
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
