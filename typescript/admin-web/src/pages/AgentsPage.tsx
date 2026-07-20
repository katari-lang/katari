import { FunctionSquare } from "lucide-react";
import { useParams, useSearchParams } from "react-router-dom";
import { useAgents, useProject, useSnapshots } from "../api/queries";
import type { AgentEntry } from "../api/types";
import { AgentsTree } from "../components/agents/AgentsTree";
import { EmptyState } from "../components/ui/EmptyState";
import { Select, Switch } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { shortId } from "../lib/format";

/** Whether an agent is the project's own, rather than one it pulls in from a dependency (the wired-in
 *  stdlib included). The compiler forces every root-package module under the package name — a module
 *  is `P` or `P.<sub>` for the package `P` — and a deploy names the runtime project after that same
 *  package name, so the project's name IS its namespace root: an agent is the project's own exactly
 *  when its qualified name is that root or a descendant of it. Anything under another top-level
 *  namespace belongs to a dependency package. */
function isOwnProjectAgent(agent: AgentEntry, packageName: string): boolean {
  return agent.qualifiedName === packageName || agent.qualifiedName.startsWith(`${packageName}.`);
}

export function AgentsPage() {
  const { projectId = "" } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const snapshotParam = searchParams.get("snapshot") ?? undefined;
  const showDependencies = searchParams.get("deps") === "1";
  const project = useProject(projectId);
  const agents = useAgents(projectId, snapshotParam);
  const snapshots = useSnapshots(projectId);

  const updateParams = (next: { snapshot?: string; deps?: boolean }) => {
    const params = new URLSearchParams();
    const snapshot = next.snapshot ?? snapshotParam;
    const deps = next.deps ?? showDependencies;
    if (snapshot !== undefined && snapshot !== "") params.set("snapshot", snapshot);
    if (deps) params.set("deps", "1");
    setSearchParams(params);
  };

  // The namespace root that identifies the project's own agents. Until the project loads, no agent can
  // be classified as "own", so the default (dependency-hidden) view stays empty behind the loader.
  const packageName = project.data?.name;
  const visible = (agents.data?.agents ?? []).filter(
    (agent) =>
      showDependencies || (packageName !== undefined && isOwnProjectAgent(agent, packageName)),
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
              checked={showDependencies}
              onChange={(next) => updateParams({ deps: next })}
              label="Show dependencies"
            />
            <Select
              aria-label="Snapshot"
              className="w-56"
              value={snapshotParam ?? ""}
              onChange={(event) => updateParams({ snapshot: event.target.value })}
            >
              <option value="">head (latest)</option>
              {(snapshots.data?.items ?? []).map((snapshot) => (
                <option key={snapshot.id} value={snapshot.id}>
                  {shortId(snapshot.id)} — {snapshot.message}
                </option>
              ))}
            </Select>
          </>
        }
      />
      {agents.isPending || project.isPending ? (
        <LoadingBlock />
      ) : visible.length === 0 ? (
        <EmptyState
          icon={FunctionSquare}
          title={showDependencies ? "No agents in this snapshot" : "No project agents"}
          description={
            showDependencies
              ? "Deploy with `katari apply` to publish agents."
              : "Only dependency entries here — flip the toggle to see them, or deploy your own."
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
