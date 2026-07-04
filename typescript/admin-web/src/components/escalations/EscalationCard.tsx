// One open escalation, answerable in place: the question (the request's argument), a schema-driven
// answer form when the request declares an answer type, and the raw-JSON fallback otherwise.
// `never`-typed requests (throw) cannot be answered — the only way out is cancelling the run.

import { useState } from "react";
import { Link } from "react-router-dom";
import { useAnswerEscalation } from "../../api/queries";
import type { Escalation, Json } from "../../api/types";
import { formatDateTime, relativeTime } from "../../lib/format";
import { useToast } from "../../lib/toast";
import { SchemaForm } from "../schema-form/SchemaForm";
import { Badge } from "../ui/Badge";
import { Button } from "../ui/Button";
import { Card, CardBody, CardHeader } from "../ui/Card";
import { CopyableId } from "../ui/Copy";
import { ValueBlock } from "../values/ValueViewer";
import { FormContextForRun, useRunSnapshot } from "./run-snapshot";

export function EscalationCard({
  projectId,
  escalation,
  showRunLink = true,
}: {
  projectId: string;
  escalation: Escalation;
  showRunLink?: boolean;
}) {
  const toast = useToast();
  const answerMutation = useAnswerEscalation(projectId);
  const [answer, setAnswer] = useState<Json | undefined>(undefined);
  const snapshotId = useRunSnapshot(projectId, escalation.runId);

  const unanswerable = isNeverSchema(escalation.answerSchema);

  const submit = () => {
    answerMutation.mutate(
      { escalationId: escalation.id, value: answer ?? null },
      {
        onSuccess: () => toast("Answer sent."),
        onError: (error) => toast(error.message, "error"),
      },
    );
  };

  return (
    <Card>
      <CardHeader
        title={
          <span className="inline-flex items-center gap-2 font-mono">
            {escalation.request}
            <CopyableId id={escalation.id} />
          </span>
        }
        actions={
          <span className="flex items-center gap-2 text-xs text-fg-faint">
            <span title={formatDateTime(escalation.createdAt)}>
              {relativeTime(escalation.createdAt)}
            </span>
            {showRunLink && (
              <Link
                to={`/projects/${projectId}/runs/${escalation.runId}`}
                className="text-accent hover:underline"
              >
                view run
              </Link>
            )}
          </span>
        }
      />
      <CardBody className="flex flex-col gap-4">
        <div>
          <SectionLabel text="Question" />
          <ValueBlock value={escalation.argument} projectId={projectId} />
        </div>
        <div>
          <SectionLabel text="Answer" />
          {unanswerable ? (
            <Badge tone="danger">unanswerable (never) — cancel the run to resolve it</Badge>
          ) : (
            <div className="flex flex-col gap-3">
              <SchemaForm
                schema={escalation.answerSchema ?? {}}
                value={answer}
                onChange={setAnswer}
                context={FormContextForRun(projectId, snapshotId)}
              />
              <Button
                variant="primary"
                className="self-start"
                loading={answerMutation.isPending}
                onClick={submit}
              >
                Send answer
              </Button>
            </div>
          )}
        </div>
      </CardBody>
    </Card>
  );
}

function SectionLabel({ text }: { text: string }) {
  return <p className="pb-1.5 text-xs font-medium text-fg-faint uppercase">{text}</p>;
}

function isNeverSchema(schema: Escalation["answerSchema"]): boolean {
  // `never` canonicalises to an unsatisfiable schema ({"not": {}} or false-like shapes).
  if (schema === null) return false;
  return "not" in schema && JSON.stringify(schema.not) === "{}";
}
