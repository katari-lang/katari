import { Link, useParams } from "react-router-dom";
import { isLiveRun, useEscalations, useHeadSnapshot, useProject, useRuns } from "../api/queries";
import { RunStateBadge } from "../components/runs/RunStateBadge";
import { Card, CardBody, CardHeader } from "../components/ui/Card";
import { CopyableId } from "../components/ui/Copy";
import { KeyValueList, KeyValueRow } from "../components/ui/KeyValue";
import { MarkdownContent } from "../components/ui/MarkdownContent";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { formatDateTime, relativeTime } from "../lib/format";

export function DashboardPage() {
  const { projectId = "" } = useParams();
  const project = useProject(projectId);
  const runs = useRuns(projectId, { limit: 25 });
  const escalations = useEscalations(projectId);
  const head = useHeadSnapshot(projectId);

  if (project.isPending) return <LoadingBlock />;
  if (project.data === undefined) return null;

  const liveRuns = (runs.data?.items ?? []).filter(isLiveRun);
  const recentRuns = (runs.data?.items ?? []).slice(0, 5);

  return (
    <>
      <PageHeader title={project.data.name} description={project.data.description} />
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader title="Active runs" actions={<SeeAll to={`/projects/${projectId}/runs`} />} />
          <CardBody className="p-0">
            {liveRuns.length === 0 ? (
              <Quiet text="Nothing running right now." />
            ) : (
              <MiniRunList projectId={projectId} runIds={liveRuns.map((run) => run.id)} />
            )}
          </CardBody>
        </Card>
        <Card>
          <CardHeader
            title="Open escalations"
            actions={<SeeAll to={`/projects/${projectId}/escalations`} />}
          />
          <CardBody className="p-0">
            {(escalations.data ?? []).length === 0 ? (
              <Quiet text="No questions waiting on you." />
            ) : (
              <ul className="divide-y divide-edge">
                {(escalations.data ?? []).slice(0, 5).map((escalation) => (
                  <li key={escalation.id}>
                    <Link
                      to={`/projects/${projectId}/escalations`}
                      className="flex items-center justify-between gap-2 px-4 py-2.5 text-sm transition-colors hover:bg-sunken"
                    >
                      <span className="font-mono">{escalation.request}</span>
                      <span
                        className="text-xs text-fg-faint"
                        title={formatDateTime(escalation.createdAt)}
                      >
                        {relativeTime(escalation.createdAt)}
                      </span>
                    </Link>
                  </li>
                ))}
              </ul>
            )}
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Recent runs" actions={<SeeAll to={`/projects/${projectId}/runs`} />} />
          <CardBody className="p-0">
            {recentRuns.length === 0 ? (
              <Quiet text="No runs yet — invoke an agent from the Agents page." />
            ) : (
              <MiniRunList projectId={projectId} runIds={recentRuns.map((run) => run.id)} />
            )}
          </CardBody>
        </Card>
        <Card>
          <CardHeader title="Project" />
          <CardBody>
            <KeyValueList>
              <KeyValueRow label="Id">
                <CopyableId id={project.data.id} />
              </KeyValueRow>
              <KeyValueRow label="Created">{formatDateTime(project.data.createdAt)}</KeyValueRow>
              <KeyValueRow label="Head snapshot">
                {head.data?.id == null ? (
                  <span className="text-fg-faint">not deployed</span>
                ) : (
                  <CopyableId id={head.data.id} />
                )}
              </KeyValueRow>
              {head.data?.message != null && (
                <KeyValueRow label="Deploy message">{head.data.message}</KeyValueRow>
              )}
            </KeyValueList>
          </CardBody>
        </Card>
      </div>
      {project.data.readme !== null && (
        <Card className="mt-4">
          <CardHeader title="README" />
          <CardBody>
            <MarkdownContent source={project.data.readme} />
          </CardBody>
        </Card>
      )}
    </>
  );
}

function MiniRunList({ projectId, runIds }: { projectId: string; runIds: string[] }) {
  const runs = useRuns(projectId, { limit: 25 });
  const byId = new Map((runs.data?.items ?? []).map((run) => [run.id, run]));
  return (
    <ul className="divide-y divide-edge">
      {runIds.map((runId) => {
        const run = byId.get(runId);
        if (run === undefined) return null;
        return (
          <li key={run.id}>
            <Link
              to={`/projects/${projectId}/runs/${run.id}`}
              className="flex items-center justify-between gap-2 px-4 py-2.5 text-sm transition-colors hover:bg-sunken"
            >
              <span className="inline-flex items-center gap-2">
                <RunStateBadge state={run.state} />
                <span className="font-medium">{run.name}</span>
              </span>
              <span className="text-xs text-fg-faint" title={formatDateTime(run.createdAt)}>
                {relativeTime(run.createdAt)}
              </span>
            </Link>
          </li>
        );
      })}
    </ul>
  );
}

function SeeAll({ to }: { to: string }) {
  return (
    <Link to={to} className="text-xs text-accent hover:underline">
      see all
    </Link>
  );
}

function Quiet({ text }: { text: string }) {
  return <p className="px-4 py-6 text-center text-sm text-fg-faint">{text}</p>;
}
