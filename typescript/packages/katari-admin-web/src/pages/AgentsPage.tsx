import { Link, useNavigate, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Activity } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import { AgentStatusBadge, isTerminalState } from "@/components/domain/AgentStatusBadge";
import { formatDateTime, relativeTime, shortId } from "@/lib/format";
import type { ProjectId } from "@/api/types";

const POLL_MS = 3_000;

export function AgentsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const client = useApiClient();
  const navigate = useNavigate();
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["agents", projectId],
    queryFn: () => client.listAgents({ projectId: projectId as ProjectId, limit: 200 }),
    enabled: typeof projectId === "string",
    refetchInterval: (query) => {
      const rows = query.state.data?.agents ?? [];
      const anyLive = rows.some((a) => !isTerminalState(a.state));
      return anyLive ? POLL_MS : false;
    },
  });

  return (
    <div>
      <PageHeader
        title="Agents"
        description="Running and recently finished agents, refreshed every 3s while any are live."
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load agents."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {data.agents.length === 0 ? (
              <EmptyState
                icon={Activity}
                title="No agents yet"
                description="Run an agent from the Definitions page to populate this list."
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>State</TH>
                    <TH>Agent</TH>
                    <TH>Snapshot</TH>
                    <TH>Created</TH>
                    <TH>Updated</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.agents.map((agent) => (
                    <TR
                      key={agent.id}
                      className="cursor-pointer"
                      onClick={() => navigate(`/project/${projectId}/agents/${agent.id}`)}
                    >
                      <TD>
                        <AgentStatusBadge state={agent.state} />
                      </TD>
                      <TD>
                        <Link
                          to={`/project/${projectId}/agents/${agent.id}`}
                          className="block hover:underline"
                          onClick={(e) => e.stopPropagation()}
                        >
                          <div className="font-medium text-foreground">
                            {agent.qualifiedName}
                          </div>
                          <div className="mt-0.5 font-mono text-[11px] text-subtle-foreground">
                            {shortId(agent.id)}
                          </div>
                        </Link>
                      </TD>
                      <TD className="font-mono text-xs text-muted-foreground">
                        {shortId(agent.snapshotId)}
                      </TD>
                      <TD className="text-xs text-muted-foreground" title={formatDateTime(agent.createdAt)}>
                        {relativeTime(agent.createdAt)}
                      </TD>
                      <TD className="text-xs text-muted-foreground" title={formatDateTime(agent.updatedAt)}>
                        {relativeTime(agent.updatedAt)}
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
