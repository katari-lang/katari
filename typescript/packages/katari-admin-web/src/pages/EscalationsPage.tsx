import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { MessageCircleQuestion } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { relativeTime, formatDateTime } from "@/lib/format";
import type { EscalationState, ProjectId } from "@/api/types";

const POLL_MS = 3_000;

const stateOptions: { value: EscalationState | "all"; label: string }[] = [
  { value: "open", label: "Open" },
  { value: "answered", label: "Answered" },
  { value: "cancelled", label: "Cancelled" },
  { value: "all", label: "All" },
];

const stateTones: Record<EscalationState, "info" | "success" | "neutral"> = {
  open: "info",
  answered: "success",
  cancelled: "neutral",
};

export function EscalationsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const client = useApiClient();
  const [stateFilter, setStateFilter] = useState<EscalationState | "all">(
    "open",
  );
  const navigate = useNavigate();

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["escalations", projectId, stateFilter],
    queryFn: () =>
      client.listEscalations({
        projectId: projectId as ProjectId,
        state: stateFilter === "all" ? undefined : stateFilter,
        limit: 200,
      }),
    enabled: typeof projectId === "string",
    refetchInterval: stateFilter === "open" ? POLL_MS : false,
  });

  // Run name lookup so the table can show the run a question was raised
  // from by name rather than a delegation UUID. Cache is shared with
  // RunsPage so visiting that page beforehand makes this free.
  const runsQ = useQuery({
    queryKey: ["runs", projectId],
    queryFn: () =>
      client.listRuns({ projectId: projectId as ProjectId, limit: 200 }),
    enabled: typeof projectId === "string",
  });
  const runNameById = new Map(
    (runsQ.data?.runs ?? []).map((r) => [r.id, r.name]),
  );

  return (
    <div>
      <PageHeader
        title="Escalations"
        description="Questions that need a human answer"
        docs={{ slug: "concepts/escalations", title: "About escalations" }}
        actions={
          <div className="flex items-center border border-border">
            {stateOptions.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setStateFilter(opt.value)}
                className={
                  stateFilter === opt.value
                    ? "bg-accent px-3 py-1.5 text-xs font-medium text-accent-foreground hover:cursor-pointer"
                    : "px-3 py-1.5 text-xs font-medium text-muted-foreground transition-colors hover:bg-muted hover:cursor-pointer"
                }
              >
                {opt.label}
              </button>
            ))}
          </div>
        }
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error
              ? error.message
              : "Failed to load escalations."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {data.escalations.length === 0 ? (
              <EmptyState
                icon={MessageCircleQuestion}
                title="No escalations"
                description={
                  stateFilter === "open"
                    ? "AI-to-user questions will appear here."
                    : "Nothing matches this filter."
                }
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>State</TH>
                    <TH>Request</TH>
                    <TH>Run</TH>
                    <TH>Created</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.escalations.map((esc) => (
                    <TR
                      key={esc.id}
                      className="cursor-pointer"
                      onClick={() =>
                        navigate(`/project/${projectId}/escalations/${esc.id}`)
                      }
                    >
                      <TD>
                        <Badge tone={stateTones[esc.state]}>{esc.state}</Badge>
                      </TD>
                      <TD>
                        <Link
                          to={`/project/${projectId}/escalations/${esc.id}`}
                          className="block font-medium text-foreground hover:underline"
                          onClick={(e) => e.stopPropagation()}
                        >
                          {esc.agentDefId}
                        </Link>
                      </TD>
                      <TD className="text-xs text-muted-foreground">
                        <Link
                          to={`/project/${projectId}/runs/${esc.rootDelegationId}`}
                          className="hover:underline hover:text-foreground"
                          onClick={(e) => e.stopPropagation()}
                        >
                          {runNameById.get(esc.rootDelegationId) ?? "—"}
                        </Link>
                      </TD>
                      <TD
                        className="text-xs text-muted-foreground"
                        title={formatDateTime(esc.createdAt)}
                      >
                        {relativeTime(esc.createdAt)}
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
