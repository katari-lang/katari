import { Link, useNavigate, useParams } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { ArrowLeft } from "lucide-react";
import toast from "react-hot-toast";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { Badge } from "@/components/ui/Badge";
import { SchemaForm } from "@/components/schema-form/SchemaForm";
import { ValueViewer } from "@/components/domain/ValueViewer";
import { formatDateTime } from "@/lib/format";
import { isNeverSchema, type JsonSchema } from "@/components/schema-form/schema-utils";
import type { EscalationId, EscalationState, ProjectId } from "@/api/types";
import type { RawValue } from "@katari-lang/runtime";

const stateTones: Record<EscalationState, "info" | "success" | "neutral"> = {
  open: "info",
  answered: "success",
  cancelled: "neutral",
};

export function EscalationDetailPage() {
  const { projectId, escalationId } = useParams<{
    projectId: string;
    escalationId: string;
  }>();
  const client = useApiClient();
  const queryClient = useQueryClient();
  const navigate = useNavigate();

  const escalationQ = useQuery({
    queryKey: ["escalation", escalationId],
    queryFn: () =>
      client.getEscalation(projectId as ProjectId, escalationId as EscalationId),
    enabled: typeof projectId === "string" && typeof escalationId === "string",
  });

  const escalation = escalationQ.data?.escalation;

  const definitionsQ = useQuery({
    queryKey: [
      "definitions",
      projectId,
      escalation?.snapshotId ?? "latest",
    ],
    queryFn: () =>
      client.listAgentDefinitions({
        projectId: projectId as ProjectId,
        snapshotId: escalation?.snapshotId,
      }),
    enabled: typeof projectId === "string" && escalation !== undefined,
  });

  const requestDef = definitionsQ.data?.definitions.find(
    (d) => d.qualifiedName === escalation?.agentDefId,
  );

  const answer = useMutation({
    mutationFn: async (value: RawValue) => {
      if (escalation === undefined) throw new Error("No escalation");
      await client.answerEscalation(
        projectId as ProjectId,
        escalation.id,
        value,
      );
    },
    onSuccess: () => {
      toast.success("Escalation answered");
      void queryClient.invalidateQueries({ queryKey: ["escalations"] });
      void queryClient.invalidateQueries({ queryKey: ["escalation", escalationId] });
      navigate(`/project/${projectId}/escalations`);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed.");
    },
  });

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex flex-wrap items-center gap-3">
            <Link
              to={`/project/${projectId}/escalations`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Escalations</span>
            </Link>
            <span className="text-subtle-foreground text-sm">/</span>
            <span className="break-all font-mono text-base">
              {escalation?.agentDefId ?? escalationId}
            </span>
            {escalation !== undefined && (
              <Badge tone={stateTones[escalation.state]}>{escalation.state}</Badge>
            )}
          </span>
        }
      />
      <PageContent>
        {escalationQ.isLoading && <SpinnerOverlay />}
        {escalationQ.isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {escalationQ.error instanceof Error
              ? escalationQ.error.message
              : "Failed to load escalation."}
          </p>
        )}
        {escalation !== undefined && (
          <motion.div
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.2 }}
            className="grid gap-4 lg:grid-cols-3"
          >
            <Card className="lg:col-span-2">
              <CardHeader>
                <CardTitle>Answer</CardTitle>
              </CardHeader>
              <CardContent>
                {escalation.state !== "open" ? (
                  <p className="text-sm text-muted-foreground">
                    This escalation is{" "}
                    <span className="font-medium text-foreground">
                      {escalation.state}
                    </span>{" "}
                    — no further action is needed.
                  </p>
                ) : definitionsQ.isLoading ? (
                  <SpinnerOverlay />
                ) : requestDef === undefined ? (
                  <p className="border border-warning/30 bg-warning/10 px-3 py-2 text-sm text-warning">
                    Could not locate the request schema for{" "}
                    <code className="font-mono">{escalation.agentDefId}</code>.
                  </p>
                ) : isNeverSchema(requestDef.returns as JsonSchema) ? (
                  // `never` return: the request was declared `-> never`,
                  // so no value can validly resume the calling thread.
                  // Surface that explicitly. We still send an `Acknowledge`
                  // to unblock the runtime — proper "cancel / error"
                  // propagation is on the D-12 followup.
                  <div className="space-y-3">
                    <div className="border border-warning/40 bg-warning/10 px-3 py-2 text-sm text-warning">
                      <p className="font-medium">
                        This request returns <code className="font-mono">never</code>.
                      </p>
                      <p className="mt-1 text-xs">
                        The calling agent does not expect any value back.
                        Consider whether the agent should fail (error state)
                        or whether this escalation should be cancelled.
                        Runtime-side cancel propagation is a known followup;
                        for now, acknowledging dismisses the escalation
                        without resuming the call.
                      </p>
                    </div>
                    <div className="flex justify-end gap-2">
                      <Link to={`/project/${projectId}/escalations`}>
                        <Button type="button" variant="secondary">
                          Back
                        </Button>
                      </Link>
                      <Button
                        type="button"
                        variant="danger"
                        onClick={() => answer.mutate(null as RawValue)}
                        loading={answer.isPending}
                      >
                        Acknowledge &amp; dismiss
                      </Button>
                    </div>
                  </div>
                ) : (
                  <SchemaForm
                    schema={requestDef.returns as JsonSchema}
                    onSubmit={(value) => answer.mutate(value as RawValue)}
                    renderActions={({ submit }) => (
                      <div className="flex justify-end gap-2 pt-2">
                        <Link to={`/project/${projectId}/escalations`}>
                          <Button type="button" variant="secondary">
                            Cancel
                          </Button>
                        </Link>
                        <Button
                          type="button"
                          variant="primary"
                          onClick={submit}
                          loading={answer.isPending}
                        >
                          Submit answer
                        </Button>
                      </div>
                    )}
                  />
                )}
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Context</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="space-y-3 text-sm">
                  <Row
                    label="Request"
                    value={
                      <code className="font-mono text-xs">{escalation.agentDefId}</code>
                    }
                  />
                  <Row
                    label="Delegation"
                    value={
                      <code className="font-mono text-xs break-all">
                        {escalation.delegationId}
                      </code>
                    }
                  />
                  <Row
                    label="Snapshot"
                    value={
                      <code className="font-mono text-xs break-all">
                        {escalation.snapshotId}
                      </code>
                    }
                  />
                  <Row label="Created" value={formatDateTime(escalation.createdAt)} />
                </dl>
              </CardContent>
            </Card>
            <Card className="lg:col-span-3">
              <CardHeader>
                <CardTitle>Args sent by the agent</CardTitle>
              </CardHeader>
              <CardContent>
                <ValueViewer value={escalation.args} />
              </CardContent>
            </Card>
            {escalation.value !== undefined && (
              <Card className="lg:col-span-3">
                <CardHeader>
                  <CardTitle>Previously submitted answer</CardTitle>
                </CardHeader>
                <CardContent>
                  <ValueViewer value={escalation.value} />
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
      <dt className="text-[11px] uppercase tracking-wider text-subtle-foreground">
        {label}
      </dt>
      <dd className="text-right text-foreground">{value}</dd>
    </div>
  );
}
