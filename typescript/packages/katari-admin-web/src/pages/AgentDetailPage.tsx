import { useMutation, useQuery } from "@tanstack/react-query";
import {
  Link,
  useNavigate,
  useParams,
  useSearchParams,
} from "react-router-dom";
import { motion } from "framer-motion";
import { ArrowLeft, Play, ChevronDown, ChevronRight } from "lucide-react";
import toast from "react-hot-toast";
import { useState } from "react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { CopyableId } from "@/components/ui/CopyableId";
import { Input } from "@/components/ui/Input";
import { Label } from "@/components/ui/Label";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { MetadataRow } from "@/components/ui/MetadataRow";
import { SchemaForm } from "@/components/schema-form/SchemaForm";
import { ValueViewer } from "@/components/domain/ValueViewer";
import type { JsonSchema } from "@/components/schema-form/schema-utils";
import { useSnapshotMessage } from "@/hooks/useSnapshotMessage";
import type { ProjectId, SnapshotId } from "@/api/types";
import type { RawValue } from "@katari-lang/runtime";

export function AgentDetailPage() {
  const { projectId, qualifiedName } = useParams<{
    projectId: string;
    qualifiedName: string;
  }>();
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const client = useApiClient();

  const snapshotParam = params.get("snapshot");
  const selectedSnapshot: SnapshotId | undefined =
    snapshotParam === null || snapshotParam === "latest"
      ? undefined
      : (snapshotParam as SnapshotId);

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["agents", projectId, selectedSnapshot ?? "latest"],
    queryFn: () =>
      client.listAgents({
        projectId: projectId as ProjectId,
        snapshotId: selectedSnapshot,
      }),
    enabled: typeof projectId === "string",
  });

  const agent = data?.agents.find((a) => a.qualifiedName === qualifiedName);
  const resolvedSnapshotId = data?.snapshotId;

  const { getMessage } = useSnapshotMessage(projectId);
  const snapshotMessage = getMessage(resolvedSnapshotId);

  // Operator-supplied run label. Empty = let the server pick a default
  // (typically `"<qualifiedName> @ HH:mm"`), so the placeholder previews
  // what will be stored if the field is left blank.
  const [runName, setRunName] = useState("");

  const invoke = useMutation({
    mutationFn: (args: Record<string, RawValue>) =>
      client.startRun({
        projectId: projectId as ProjectId,
        snapshotId: selectedSnapshot,
        qualifiedName: qualifiedName ?? "",
        name: runName.trim() === "" ? null : runName.trim(),
        args,
      }),
    onSuccess: (res) => {
      toast.success("Run started");
      navigate(`/project/${projectId}/runs/${res.runId}`);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Run failed to start");
    },
  });

  const namePlaceholder = defaultRunNamePreview(qualifiedName);

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex flex-wrap items-center gap-3">
            <Link
              to={`/project/${projectId}/agents${
                selectedSnapshot !== undefined
                  ? `?snapshot=${selectedSnapshot}`
                  : ""
              }`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Agents</span>
            </Link>
            <span className="text-subtle-foreground text-sm">/</span>
            <span className="break-all font-mono text-base text-foreground">
              {qualifiedName}
            </span>
          </span>
        }
        description={agent?.description}
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load agent."}
          </p>
        )}
        {!isLoading && data !== undefined && agent === undefined && (
          <p className=" border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
            No agent <code className="font-mono">{qualifiedName}</code> in this
            snapshot.
          </p>
        )}
        {agent !== undefined && (
          <motion.div
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.2 }}
            className="grid gap-4 lg:grid-cols-3"
          >
            <Card className="lg:col-span-2">
              <CardHeader>
                <CardTitle>Invoke</CardTitle>
              </CardHeader>
              <CardContent>
                <div className="space-y-4">
                  <div className="space-y-1.5">
                    <Label htmlFor="run-name">Name</Label>
                    <Input
                      id="run-name"
                      value={runName}
                      onChange={(e) => setRunName(e.target.value)}
                      placeholder={namePlaceholder}
                      maxLength={128}
                    />
                    <p className="text-xs text-subtle-foreground">
                      Optional — defaults to the placeholder.
                    </p>
                  </div>
                  <SchemaForm
                    schema={agent.parameters as JsonSchema}
                    onSubmit={(args) =>
                      invoke.mutate(args as Record<string, RawValue>)
                    }
                    renderActions={({ submit }) => (
                      <div className="flex justify-end pt-2">
                        <Button
                          type="button"
                          variant="primary"
                          onClick={submit}
                          loading={invoke.isPending}
                        >
                          <Play className="size-4" />
                          Run agent
                        </Button>
                      </div>
                    )}
                  />
                </div>
              </CardContent>
            </Card>
            <Card>
              <CardHeader>
                <CardTitle>Metadata</CardTitle>
              </CardHeader>
              <CardContent>
                <dl className="space-y-2 text-sm">
                  <MetadataRow
                    label="ID"
                    value={<CopyableId value={agent.qualifiedName} />}
                  />
                  {resolvedSnapshotId !== undefined && (
                    <MetadataRow
                      label="Snapshot"
                      value={
                        <Link
                          to={`/project/${projectId}/agents?snapshot=${resolvedSnapshotId}`}
                          className="text-foreground hover:underline"
                        >
                          {snapshotMessage ?? "—"}
                        </Link>
                      }
                    />
                  )}
                </dl>
              </CardContent>
            </Card>
            <ReturnsCard
              returns={agent.returns}
              className="lg:col-span-3"
            />
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}

/** Mirrors the server's default-name format so the placeholder previews
 *  what will actually be stored. Time is local to the browser, which is
 *  also where the operator is looking — server-stamped time may differ
 *  slightly but the format matches. */
function defaultRunNamePreview(qualifiedName: string | undefined): string {
  const now = new Date();
  const h = String(now.getHours()).padStart(2, "0");
  const m = String(now.getMinutes()).padStart(2, "0");
  return `${qualifiedName ?? "agent"} @ ${h}:${m}`;
}

function ReturnsCard({
  returns,
  className,
}: {
  returns: unknown;
  className?: string;
}) {
  // Default-open: operators almost always want to see the response shape
  // before invoking, so collapsing it adds a needless click.
  const [open, setOpen] = useState(true);
  return (
    <Card className={className}>
      <CardHeader>
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          className="flex items-center justify-between gap-2 text-left hover:cursor-pointer"
        >
          <CardTitle>Returns schema</CardTitle>
          {open ? (
            <ChevronDown className="size-4 text-muted-foreground" />
          ) : (
            <ChevronRight className="size-4 text-muted-foreground" />
          )}
        </button>
      </CardHeader>
      {open && (
        <CardContent>
          <ValueViewer value={returns} />
        </CardContent>
      )}
    </Card>
  );
}
