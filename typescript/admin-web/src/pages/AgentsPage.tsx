import { FunctionSquare } from "lucide-react";
import { useParams, useSearchParams } from "react-router-dom";
import { useAgents, useSnapshots } from "../api/queries";
import { AgentsTree, isStdlibAgent } from "../components/agents/AgentsTree";
import { EmptyState } from "../components/ui/EmptyState";
import { Select, Switch } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { shortId } from "../lib/format";

export function AgentsPage() {
  const { projectId = "" } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const snapshotParam = searchParams.get("snapshot") ?? undefined;
  const showStdlib = searchParams.get("stdlib") === "1";
  const agents = useAgents(projectId, snapshotParam);
  const snapshots = useSnapshots(projectId);

  const updateParams = (next: { snapshot?: string; stdlib?: boolean }) => {
    const params = new URLSearchParams();
    const snapshot = next.snapshot ?? snapshotParam;
    const stdlib = next.stdlib ?? showStdlib;
    if (snapshot !== undefined && snapshot !== "") params.set("snapshot", snapshot);
    if (stdlib) params.set("stdlib", "1");
    setSearchParams(params);
  };

  const visible = (agents.data?.agents ?? []).filter(
    (agent) => showStdlib || !isStdlibAgent(agent),
  );

  return (
    <>
      <PageHeader
        title="Agents"
        description={
          agents.data !== undefined && (
            <span>
              snapshot <span className="font-mono">{shortId(agents.data.snapshotId)}</span>
            </span>
          )
        }
        actions={
          <>
            <Switch
              checked={showStdlib}
              onChange={(next) => updateParams({ stdlib: next })}
              label="Show stdlib"
            />
            <Select
              aria-label="Snapshot"
              className="w-56"
              value={snapshotParam ?? ""}
              onChange={(event) => updateParams({ snapshot: event.target.value })}
            >
              <option value="">head (latest)</option>
              {(snapshots.data ?? []).map((snapshot) => (
                <option key={snapshot.id} value={snapshot.id}>
                  {shortId(snapshot.id)} — {snapshot.message}
                </option>
              ))}
            </Select>
          </>
        }
      />
      {agents.isPending ? (
        <LoadingBlock />
      ) : visible.length === 0 ? (
        <EmptyState
          icon={FunctionSquare}
          title={showStdlib ? "No agents in this snapshot" : "No project agents"}
          description={
            showStdlib
              ? "Deploy with `katari apply` to publish agents."
              : "Only stdlib entries here — flip the toggle to see them, or deploy your own."
          }
        />
      ) : (
        <div className="border border-edge">
          <AgentsTree projectId={projectId} agents={visible} snapshotId={snapshotParam} />
        </div>
      )}
    </>
  );
}
