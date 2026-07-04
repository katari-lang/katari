// One agent: invoke it with a schema-driven argument form, and read its input / output schemas.

import { ChevronLeft, ClipboardPaste, Play } from "lucide-react";
import { useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router-dom";
import { useAgent, useStartRun } from "../api/queries";
import type { Json } from "../api/types";
import { SchemaViewer } from "../components/schema/SchemaViewer";
import { SchemaForm } from "../components/schema-form/SchemaForm";
import { Button } from "../components/ui/Button";
import { Card, CardBody, CardHeader } from "../components/ui/Card";
import { CopyableId } from "../components/ui/Copy";
import { Input, Label } from "../components/ui/Field";
import { MarkdownContent } from "../components/ui/MarkdownContent";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { useToast } from "../lib/toast";

export function AgentDetailPage() {
  const { projectId = "", qualifiedName = "" } = useParams();
  const [searchParams] = useSearchParams();
  const snapshotParam = searchParams.get("snapshot") ?? undefined;
  const agent = useAgent(projectId, qualifiedName, snapshotParam);
  const startMutation = useStartRun(projectId);
  const toast = useToast();
  const navigate = useNavigate();
  const [runName, setRunName] = useState("");
  const [argument, setArgument] = useState<Json | undefined>(undefined);
  // Bumped on paste to remount the argument form, so every field re-reads the pasted value — some fields
  // carry their own state (the raw-JSON buffer, a union's selected branch) that a prop change alone misses.
  const [argumentFormKey, setArgumentFormKey] = useState(0);

  if (agent.isPending) return <LoadingBlock />;
  if (agent.data === undefined) return null;
  const detail = agent.data;

  const start = () => {
    startMutation.mutate(
      {
        qualifiedName,
        ...(runName === "" ? {} : { name: runName }),
        ...(snapshotParam === undefined ? {} : { snapshotId: snapshotParam }),
        ...(argument === undefined ? {} : { argument }),
      },
      {
        onSuccess: ({ id }) => navigate(`/projects/${projectId}/runs/${id}`),
        onError: (error) => toast(error.message, "error"),
      },
    );
  };

  // Fill the argument form from the clipboard — e.g. a JSON value copied off another run's argument /
  // result (both offer a "Copy JSON"). Invalid JSON is a toast, not a throw.
  const pasteArgument = async () => {
    try {
      const parsed: Json = JSON.parse(await navigator.clipboard.readText());
      setArgument(parsed);
      setArgumentFormKey((previous) => previous + 1);
      toast("Pasted argument from clipboard.");
    } catch {
      toast("Clipboard did not contain valid JSON.", "error");
    }
  };

  return (
    <>
      <PageHeader
        title={
          <span className="inline-flex items-center gap-3">
            <Link to={`/projects/${projectId}/agents`} className="text-fg-faint hover:text-fg">
              <ChevronLeft className="size-5" />
            </Link>
            <span className="font-mono">{qualifiedName}</span>
          </span>
        }
        description={
          <span className="inline-flex items-center gap-1">
            snapshot <CopyableId id={detail.snapshotId} />
          </span>
        }
      />
      {detail.description !== "" && (
        <div className="max-w-3xl pb-5">
          <MarkdownContent source={detail.description} />
        </div>
      )}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader
            title="Invoke"
            actions={
              <Button size="sm" onClick={() => void pasteArgument()}>
                <ClipboardPaste className="size-3.5" /> Paste
              </Button>
            }
          />
          <CardBody className="flex flex-col gap-4">
            <Label text="Run name" hint="optional">
              <Input
                value={runName}
                onChange={(event) => setRunName(event.target.value)}
                placeholder={`${qualifiedName} @ ${new Date().toLocaleTimeString()}`}
              />
            </Label>
            <Label text="Argument">
              <SchemaForm
                key={argumentFormKey}
                schema={detail.input}
                value={argument}
                onChange={setArgument}
                context={{ projectId, snapshotId: detail.snapshotId }}
              />
            </Label>
            <Button
              variant="primary"
              className="self-start"
              loading={startMutation.isPending}
              onClick={start}
            >
              <Play className="size-4" /> Run
            </Button>
          </CardBody>
        </Card>
        <div className="flex flex-col gap-4">
          <Card>
            <CardHeader title="Input schema" />
            <CardBody>
              <SchemaViewer schema={detail.input} />
            </CardBody>
          </Card>
          <Card>
            <CardHeader title="Output schema" />
            <CardBody>
              <SchemaViewer schema={detail.output} />
            </CardBody>
          </Card>
        </div>
      </div>
    </>
  );
}
