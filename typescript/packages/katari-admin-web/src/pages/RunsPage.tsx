import { Link, useNavigate, useParams } from "react-router-dom";
import { useInfiniteQuery } from "@tanstack/react-query";
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
import { useSnapshotMessage } from "@/hooks/useSnapshotMessage";
import type { ProjectId } from "@/api/types";

const POLL_MS = 3_000;
const PAGE_SIZE = 50;

export function RunsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const client = useApiClient();
  const navigate = useNavigate();
  const {
    data,
    isLoading,
    isError,
    error,
    fetchNextPage,
    hasNextPage,
    isFetchingNextPage,
  } = useInfiniteQuery({
    queryKey: ["runs", projectId],
    queryFn: ({ pageParam }) =>
      client.listRuns({
        projectId: projectId as ProjectId,
        limit: PAGE_SIZE,
        cursor: pageParam ?? undefined,
      }),
    initialPageParam: null as string | null,
    getNextPageParam: (lastPage) => lastPage.nextCursor,
    enabled: typeof projectId === "string",
    refetchInterval: (query) => {
      const pages = query.state.data?.pages ?? [];
      const anyLive = pages.some((p) =>
        p.runs.some((r) => !isTerminalState(r.state)),
      );
      return anyLive ? POLL_MS : false;
    },
  });

  const runs = data?.pages.flatMap((p) => p.runs) ?? [];

  const { getMessage } = useSnapshotMessage(projectId);

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
            {runs.length === 0 ? (
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
              <>
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
                    {runs.map((run) => (
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
                            {getMessage(run.snapshotId) ?? "—"}
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
                {hasNextPage && (
                  <div className="mt-4 flex justify-center">
                    <Button
                      variant="secondary"
                      size="sm"
                      loading={isFetchingNextPage}
                      onClick={() => fetchNextPage()}
                    >
                      Load more
                    </Button>
                  </div>
                )}
              </>
            )}
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}
