import { Play } from "lucide-react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useRuns } from "../api/queries";
import type { RunState } from "../api/types";
import { RunsTable } from "../components/runs/RunsTable";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { EmptyState } from "../components/ui/EmptyState";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { cn } from "../lib/cn";

const filters: Array<{ label: string; state: RunState | undefined }> = [
  { label: "All", state: undefined },
  { label: "Running", state: "running" },
  { label: "Done", state: "done" },
  { label: "Error", state: "error" },
  { label: "Cancelled", state: "cancelled" },
];

export function RunsPage() {
  const { projectId = "" } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const stateParam = searchParams.get("state") as RunState | null;
  const runs = useRuns(projectId, {
    limit: 200,
    ...(stateParam === null ? {} : { state: stateParam }),
  });

  return (
    <>
      <PageHeader
        title="Runs"
        description="Agent activations, newest first."
        actions={
          <div className="flex items-center border border-edge p-0.5">
            {filters.map(({ label, state }) => (
              <button
                key={label}
                type="button"
                onClick={() => setSearchParams(state === undefined ? {} : { state })}
                className={cn(
                  "px-2.5 py-1 text-xs text-fg-muted transition-colors hover:text-fg",
                  stateParam === (state ?? null) && "bg-sunken font-medium text-fg",
                )}
              >
                {label}
              </button>
            ))}
          </div>
        }
      />
      {runs.isPending ? (
        <LoadingBlock />
      ) : (runs.data ?? []).length === 0 ? (
        <EmptyState
          icon={Play}
          title="No runs"
          description="Invoke an agent to start one."
          action={
            <Link to={`/projects/${projectId}/agents`}>
              <Button>Browse agents</Button>
            </Link>
          }
        />
      ) : (
        <Card>
          <RunsTable projectId={projectId} runs={runs.data ?? []} />
        </Card>
      )}
    </>
  );
}
