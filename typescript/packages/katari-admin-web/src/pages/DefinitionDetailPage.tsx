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
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { SchemaForm } from "@/components/schema-form/SchemaForm";
import { ValueViewer } from "@/components/domain/ValueViewer";
import type { JsonSchema } from "@/components/schema-form/schema-utils";
import type { ProjectId, SnapshotId } from "@/api/types";
import type { RawValue } from "@katari-lang/runtime";

export function DefinitionDetailPage() {
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
    queryKey: ["definitions", projectId, selectedSnapshot ?? "latest"],
    queryFn: () =>
      client.listAgentDefinitions({
        projectId: projectId as ProjectId,
        snapshotId: selectedSnapshot,
      }),
    enabled: typeof projectId === "string",
  });

  const definition = data?.definitions.find(
    (d) => d.qualifiedName === qualifiedName,
  );

  const invoke = useMutation({
    mutationFn: (args: Record<string, RawValue>) =>
      client.startAgent({
        projectId: projectId as ProjectId,
        snapshotId: selectedSnapshot,
        qualifiedName: qualifiedName ?? "",
        args,
      }),
    onSuccess: (res) => {
      toast.success("Agent started");
      navigate(`/project/${projectId}/agents/${res.agentId}`);
    },
    onError: (err) => {
      toast.error(err instanceof Error ? err.message : "Failed to start.");
    },
  });

  return (
    <div>
      <PageHeader
        title={
          <span className="inline-flex flex-wrap items-center gap-3">
            <Link
              to={`/project/${projectId}/definitions${
                selectedSnapshot !== undefined
                  ? `?snapshot=${selectedSnapshot}`
                  : ""
              }`}
              className="inline-flex items-center gap-1 text-muted-foreground hover:text-foreground"
            >
              <ArrowLeft className="size-4" />
              <span className="text-sm font-normal">Definitions</span>
            </Link>
            <span className="text-subtle-foreground text-sm">/</span>
            <span className="break-all font-mono text-base text-foreground">
              {qualifiedName}
            </span>
          </span>
        }
        description={definition?.description}
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error
              ? error.message
              : "Failed to load definition."}
          </p>
        )}
        {!isLoading && data !== undefined && definition === undefined && (
          <p className=" border border-warning/30 bg-warning/10 px-4 py-3 text-sm text-warning">
            No definition <code className="font-mono">{qualifiedName}</code> in
            this snapshot.
          </p>
        )}
        {definition !== undefined && (
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
                <SchemaForm
                  schema={definition.parameters as JsonSchema}
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
              </CardContent>
            </Card>
            <ReturnsCard returns={definition.returns} />
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}

function ReturnsCard({ returns }: { returns: unknown }) {
  // Default-open: operators almost always want to see the response shape
  // before invoking, so collapsing it adds a needless click.
  const [open, setOpen] = useState(true);
  return (
    <Card>
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
