// The escalation inbox: every open question across the project, answerable in place. Answered
// escalations leave the inbox (their Q&A lives on in the run's escalation history).

import { Bell } from "lucide-react";
import { useParams } from "react-router-dom";
import { useEscalations } from "../api/queries";
import { EscalationCard } from "../components/escalations/EscalationCard";
import { EmptyState } from "../components/ui/EmptyState";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";

export function EscalationsPage() {
  const { projectId = "" } = useParams();
  const escalations = useEscalations(projectId);

  return (
    <>
      <PageHeader
        title="Escalations"
        description="Questions your programs escalated to a human. Answering resumes the run."
      />
      {escalations.isPending ? (
        <LoadingBlock />
      ) : (escalations.data ?? []).length === 0 ? (
        <EmptyState
          icon={Bell}
          title="Inbox zero"
          description="No run is waiting on you. Answered questions appear on their run's page."
        />
      ) : (
        <div className="flex flex-col gap-4">
          {(escalations.data ?? []).map((escalation) => (
            <EscalationCard key={escalation.id} projectId={projectId} escalation={escalation} />
          ))}
        </div>
      )}
    </>
  );
}
