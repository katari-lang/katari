import { useState } from "react";
import { useParams } from "react-router-dom";
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
import { EscalationAnswerDialog } from "@/components/domain/EscalationAnswerDialog";
import { relativeTime, formatDateTime, shortId } from "@/lib/format";
import type { EscalationState, EscalationWire, ProjectId } from "@/api/types";

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
  const [stateFilter, setStateFilter] = useState<EscalationState | "all">("open");
  const [answering, setAnswering] = useState<EscalationWire | null>(null);

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

  return (
    <div>
      <PageHeader
        title="Escalations"
        description="AI-initiated questions that need a human answer."
        actions={
          <div className="flex items-center gap-1  border border-border  p-1">
            {stateOptions.map((opt) => (
              <button
                key={opt.value}
                type="button"
                onClick={() => setStateFilter(opt.value)}
                className={
                  stateFilter === opt.value
                    ? " bg-accent px-2.5 py-1 text-xs font-medium text-accent-foreground hover:cursor-pointer"
                    : " px-2.5 py-1 text-xs font-medium text-muted-foreground transition-colors hover:bg-muted hover:cursor-pointer"
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
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load escalations."}
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
                    ? "Pending AI → user questions will show up here."
                    : "No escalations match this filter."
                }
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>State</TH>
                    <TH>Request</TH>
                    <TH>Agent</TH>
                    <TH>Created</TH>
                    <TH className="text-right">Action</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.escalations.map((esc) => (
                    <TR key={esc.escalationId}>
                      <TD>
                        <Badge tone={stateTones[esc.state]}>{esc.state}</Badge>
                      </TD>
                      <TD>
                        <div className="font-medium text-foreground">{esc.agentDefId}</div>
                        <div className="mt-0.5 font-mono text-[11px] text-subtle-foreground">
                          {shortId(esc.escalationId)}
                        </div>
                      </TD>
                      <TD className="font-mono text-xs text-muted-foreground">
                        {shortId(esc.delegationId)}
                      </TD>
                      <TD className="text-xs text-muted-foreground" title={formatDateTime(esc.createdAt)}>
                        {relativeTime(esc.createdAt)}
                      </TD>
                      <TD className="text-right">
                        {esc.state === "open" ? (
                          <Button size="sm" onClick={() => setAnswering(esc)}>
                            Answer
                          </Button>
                        ) : (
                          <span className="text-xs text-subtle-foreground">—</span>
                        )}
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </Table>
            )}
          </motion.div>
        )}
      </PageContent>
      <EscalationAnswerDialog
        escalation={answering}
        open={answering !== null}
        onClose={() => setAnswering(null)}
      />
    </div>
  );
}
