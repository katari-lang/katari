// One run: metadata, argument, live open escalations (answerable in place), the answered Q&A
// transcript, and the outcome. Polls while live and goes quiet on terminal.

import { REDACTED_KEY } from "@katari-lang/types";
import { ChevronLeft, RotateCcw } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import {
  isLiveRun,
  useCancelRun,
  useEscalations,
  useRun,
  useRunEscalationAudit,
  useRunTree,
  useStartRun,
} from "../api/queries";
import { EscalationCard } from "../components/escalations/EscalationCard";
import { DelegationTree } from "../components/runs/DelegationTree";
import { RunStateBadge } from "../components/runs/RunStateBadge";
import { Button } from "../components/ui/Button";
import { Card, CardBody, CardHeader } from "../components/ui/Card";
import { CopyableId } from "../components/ui/Copy";
import { ConfirmDialog } from "../components/ui/Dialog";
import { KeyValueList, KeyValueRow } from "../components/ui/KeyValue";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { ValueBlock } from "../components/values/ValueViewer";
import { formatDateTime } from "../lib/format";
import { useToast } from "../lib/toast";

export function RunDetailPage() {
  const { projectId = "", runId = "" } = useParams();
  const run = useRun(projectId, runId);
  const escalations = useEscalations(projectId);
  const live = run.data !== undefined && isLiveRun(run.data);
  const tree = useRunTree(projectId, runId, live);
  const audit = useRunEscalationAudit(projectId, runId, live);
  const cancelMutation = useCancelRun(projectId);
  const rerunMutation = useStartRun(projectId);
  const toast = useToast();
  const navigate = useNavigate();
  const [confirmingCancel, setConfirmingCancel] = useState(false);

  if (run.isPending) return <LoadingBlock />;
  if (run.data === undefined) return null;
  const current = run.data;

  const openForRun = (escalations.data ?? []).filter((escalation) => escalation.runId === runId);

  const rerun = () => {
    rerunMutation.mutate(
      {
        qualifiedName: current.qualifiedName,
        ...(current.snapshotId === null ? {} : { snapshotId: current.snapshotId }),
        ...(current.argument === null ? {} : { argument: current.argument }),
      },
      {
        onSuccess: ({ id }) => navigate(`/projects/${projectId}/runs/${id}`),
        onError: (error) => toast(error.message, "error"),
      },
    );
  };

  return (
    <>
      <PageHeader
        title={
          <span className="inline-flex items-center gap-3">
            <Link to={`/projects/${projectId}/runs`} className="text-fg-faint hover:text-fg">
              <ChevronLeft className="size-5" />
            </Link>
            {current.name}
            <RunStateBadge state={current.state} />
          </span>
        }
        actions={
          <>
            {/* Re-running with the same argument only makes sense once the original is decided;
                a redacted argument would replay `$redacted` markers, so it is withheld too. */}
            {!live && !containsRedaction(current.argument) && (
              <Button onClick={rerun} loading={rerunMutation.isPending}>
                <RotateCcw className="size-3.5" /> Re-run
              </Button>
            )}
            {live && (
              <Button variant="danger" onClick={() => setConfirmingCancel(true)}>
                Cancel run
              </Button>
            )}
          </>
        }
      />

      <div className="flex flex-col gap-4">
        {openForRun.map((escalation) => (
          <EscalationCard
            key={escalation.id}
            projectId={projectId}
            escalation={escalation}
            showRunLink={false}
          />
        ))}

        {/* The delegation rows are live routing, deleted on terminal — so the tree only exists while
            the run does. A live run whose tree has not landed yet (the delegate is between commits)
            shows a quiet placeholder instead of flashing the card in and out. */}
        {live && (
          <Card>
            <CardHeader title="Delegation tree" />
            <CardBody>
              {tree.data?.tree != null ? (
                <DelegationTree root={tree.data.tree} />
              ) : (
                <p className="text-sm text-fg-faint">Waiting for the first delegation to land…</p>
              )}
            </CardBody>
          </Card>
        )}

        {current.state === "error" && current.errorMessage !== null && (
          <Card className="border-danger">
            <CardHeader title="Error" />
            <CardBody>
              <pre className="overflow-x-auto font-mono text-xs whitespace-pre-wrap text-danger">
                {current.errorMessage}
              </pre>
            </CardBody>
          </Card>
        )}

        {current.state === "done" && (
          <Card>
            <CardHeader title="Result" />
            <CardBody>
              <ValueBlock value={current.result} projectId={projectId} />
            </CardBody>
          </Card>
        )}

        <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
          <Card>
            <CardHeader title="Argument" />
            <CardBody>
              <ValueBlock value={current.argument} projectId={projectId} />
            </CardBody>
          </Card>
          <Card>
            <CardHeader title="Metadata" />
            <CardBody>
              <KeyValueList>
                <KeyValueRow label="Id">
                  <CopyableId id={current.id} />
                </KeyValueRow>
                <KeyValueRow label="Agent">
                  <Link
                    to={`/projects/${projectId}/agents/${encodeURIComponent(current.qualifiedName)}`}
                    className="font-mono text-accent hover:underline"
                  >
                    {current.qualifiedName}
                  </Link>
                </KeyValueRow>
                <KeyValueRow label="Snapshot">
                  {current.snapshotId === null ? (
                    <span className="text-fg-faint">—</span>
                  ) : (
                    <CopyableId id={current.snapshotId} />
                  )}
                </KeyValueRow>
                <KeyValueRow label="Started">{formatDateTime(current.createdAt)}</KeyValueRow>
                {current.completedAt !== null && (
                  <KeyValueRow label="Finished">{formatDateTime(current.completedAt)}</KeyValueRow>
                )}
                {current.cancelReason !== null && (
                  <KeyValueRow label="Cancel reason">{current.cancelReason}</KeyValueRow>
                )}
              </KeyValueList>
            </CardBody>
          </Card>
        </div>

        {(audit.data ?? []).length > 0 && (
          <Card>
            <CardHeader title="Escalation history" />
            <CardBody className="flex flex-col gap-4">
              {(audit.data ?? []).map((entry) => (
                <div
                  key={entry.escalationId}
                  className="flex flex-col gap-2 border-l border-edge pl-3"
                >
                  <p className="text-xs text-fg-faint">{formatDateTime(entry.answeredAt)}</p>
                  <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
                    <div>
                      <p className="pb-1 text-xs font-medium text-fg-faint uppercase">Question</p>
                      <ValueBlock value={entry.question} projectId={projectId} />
                    </div>
                    <div>
                      <p className="pb-1 text-xs font-medium text-fg-faint uppercase">Answer</p>
                      <ValueBlock value={entry.answer} projectId={projectId} />
                    </div>
                  </div>
                </div>
              ))}
            </CardBody>
          </Card>
        )}
      </div>

      <ConfirmDialog
        open={confirmingCancel}
        onClose={() => setConfirmingCancel(false)}
        onConfirm={() =>
          cancelMutation.mutate(
            { runId },
            {
              onSuccess: () => {
                setConfirmingCancel(false);
                toast("Cancellation requested.");
              },
              onError: (error) => toast(error.message, "error"),
            },
          )
        }
        title="Cancel this run?"
        description="The run winds down cooperatively; open escalations are dropped with it."
        confirmLabel="Cancel run"
        busy={cancelMutation.isPending}
      />
    </>
  );
}

function containsRedaction(value: unknown): boolean {
  if (typeof value !== "object" || value === null) return false;
  if (!Array.isArray(value) && (value as { [key: string]: unknown })[REDACTED_KEY] === true) {
    return true;
  }
  return Object.values(value).some(containsRedaction);
}
