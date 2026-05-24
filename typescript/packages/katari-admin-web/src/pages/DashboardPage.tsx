import { Link, useParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Activity, ArrowRight, MessageCircleQuestion } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import {
  RunStatusBadge,
  isTerminalState,
} from "@/components/domain/RunStatusBadge";
import { formatDateTime, relativeTime, shortId } from "@/lib/format";
import type { ProjectId } from "@/api/types";

const POLL_MS = 3_000;

export function DashboardPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const client = useApiClient();

  const projectQ = useQuery({
    queryKey: ["project", projectId],
    queryFn: () => client.getProject(projectId as ProjectId),
    enabled: typeof projectId === "string",
  });

  const runsQ = useQuery({
    queryKey: ["runs", projectId],
    queryFn: () =>
      client.listRuns({ projectId: projectId as ProjectId, limit: 200 }),
    enabled: typeof projectId === "string",
    refetchInterval: (query) =>
      (query.state.data?.runs ?? []).some((r) => !isTerminalState(r.state))
        ? POLL_MS
        : false,
  });

  const escalationsQ = useQuery({
    queryKey: ["escalations", projectId, "open"],
    queryFn: () =>
      client.listEscalations({
        projectId: projectId as ProjectId,
        state: "open",
        limit: 50,
      }),
    enabled: typeof projectId === "string",
    refetchInterval: POLL_MS,
  });

  const snapshotQ = useQuery({
    queryKey: ["snapshot-latest", projectId],
    queryFn: () => client.getSnapshotLatest(projectId as ProjectId),
    enabled: typeof projectId === "string",
  });

  const runs = runsQ.data?.runs ?? [];
  const liveRuns = runs
    .filter((r) => !isTerminalState(r.state))
    .slice(0, 5);
  const recentRuns = runs.slice(0, 5);
  const openEscalations = (escalationsQ.data?.escalations ?? []).slice(0, 5);

  return (
    <div>
      <PageHeader
        title={projectQ.data?.project.name ?? "Project"}
        description={
          projectId !== undefined ? (
            <span className="font-mono text-xs">{projectId}</span>
          ) : undefined
        }
      />
      <PageContent>
        {projectQ.isLoading && <SpinnerOverlay />}
        {!projectQ.isLoading && (
          <motion.div
            initial={{ opacity: 0, y: 4 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ duration: 0.2 }}
            className="grid gap-4 lg:grid-cols-2 xl:grid-cols-3"
          >
            <DashboardCard
              title="Running runs"
              count={liveRuns.length}
              icon={<Activity className="size-4 text-highlight" />}
              footer={
                <Link to={`/project/${projectId}/runs`}>
                  <Button variant="ghost" size="sm">
                    See all
                    <ArrowRight className="size-3.5" />
                  </Button>
                </Link>
              }
            >
              {liveRuns.length === 0 ? (
                <p className="text-sm text-subtle-foreground">
                  No live runs.
                </p>
              ) : (
                <ul className="space-y-1.5">
                  {liveRuns.map((r) => (
                    <li key={r.id}>
                      <Link
                        to={`/project/${projectId}/runs/${r.id}`}
                        className="flex items-center gap-2  px-2 py-1.5 text-sm transition-colors hover:bg-muted"
                      >
                        <RunStatusBadge state={r.state} />
                        <span className="flex-1 truncate font-mono text-xs text-foreground">
                          {r.name ?? r.qualifiedName}
                        </span>
                        <span className="text-[11px] text-subtle-foreground">
                          {relativeTime(r.createdAt)}
                        </span>
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </DashboardCard>

            <DashboardCard
              title="Open escalations"
              count={openEscalations.length}
              icon={<MessageCircleQuestion className="size-4 text-warning" />}
              footer={
                <Link to={`/project/${projectId}/escalations`}>
                  <Button variant="ghost" size="sm">
                    See all
                    <ArrowRight className="size-3.5" />
                  </Button>
                </Link>
              }
            >
              {openEscalations.length === 0 ? (
                <p className="text-sm text-subtle-foreground">
                  No open escalations.
                </p>
              ) : (
                <ul className="space-y-1.5">
                  {openEscalations.map((e) => (
                    <li
                      key={e.id}
                      className=" px-2 py-1.5 text-sm hover:bg-muted"
                    >
                      <div className="flex items-center gap-2">
                        <Badge tone="info">open</Badge>
                        <span className="flex-1 truncate font-mono text-xs text-foreground">
                          {e.agentDefId}
                        </span>
                        <span className="text-[11px] text-subtle-foreground">
                          {relativeTime(e.createdAt)}
                        </span>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </DashboardCard>

            <DashboardCard title="Project info" count={null} icon={null}>
              <dl className="space-y-2 text-sm">
                <InfoRow
                  label="Project ID"
                  value={<code className="font-mono text-xs">{projectId}</code>}
                />
                {projectQ.data !== undefined && (
                  <InfoRow
                    label="Created"
                    value={
                      <span
                        title={formatDateTime(projectQ.data.project.createdAt)}
                      >
                        {relativeTime(projectQ.data.project.createdAt)}
                      </span>
                    }
                  />
                )}
                {snapshotQ.data !== undefined && (
                  <>
                    <InfoRow
                      label="Latest snapshot"
                      value={
                        <code className="font-mono text-xs">
                          {shortId(snapshotQ.data.snapshot.id, 8, 4)}
                        </code>
                      }
                    />
                    <InfoRow
                      label="Snapshot age"
                      value={
                        <span
                          title={formatDateTime(
                            snapshotQ.data.snapshot.createdAt,
                          )}
                        >
                          {relativeTime(snapshotQ.data.snapshot.createdAt)}
                        </span>
                      }
                    />
                  </>
                )}
              </dl>
            </DashboardCard>

            <DashboardCard
              title="Recent runs"
              count={null}
              icon={null}
              footer={
                <Link to={`/project/${projectId}/runs`}>
                  <Button variant="ghost" size="sm">
                    See all
                    <ArrowRight className="size-3.5" />
                  </Button>
                </Link>
              }
              className="lg:col-span-2 xl:col-span-3"
            >
              {recentRuns.length === 0 ? (
                <p className="text-sm text-subtle-foreground">
                  No runs yet. Start one from the{" "}
                  <Link
                    to={`/project/${projectId}/definitions`}
                    className="underline"
                  >
                    Definitions
                  </Link>{" "}
                  page.
                </p>
              ) : (
                <ul className="">
                  {recentRuns.map((r) => (
                    <li key={r.id}>
                      <Link
                        to={`/project/${projectId}/runs/${r.id}`}
                        className="flex items-center gap-3 px-2 py-2 text-sm transition-colors hover:bg-muted"
                      >
                        <RunStatusBadge state={r.state} />
                        <span className="flex-1 truncate font-mono text-foreground">
                          {r.name ?? r.qualifiedName}
                        </span>
                        <span className="text-[11px] text-subtle-foreground">
                          {relativeTime(r.updatedAt)}
                        </span>
                      </Link>
                    </li>
                  ))}
                </ul>
              )}
            </DashboardCard>
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}

function DashboardCard({
  title,
  count,
  icon,
  children,
  footer,
  className,
}: {
  title: string;
  count: number | null;
  icon: React.ReactNode;
  children: React.ReactNode;
  footer?: React.ReactNode;
  className?: string;
}) {
  return (
    <Card className={className}>
      <CardHeader>
        <div className="flex items-center gap-2">
          {icon}
          <CardTitle className="text-base">{title}</CardTitle>
          {count !== null && (
            <span className="ml-auto inline-flex h-5 min-w-5 items-center justify-center rounded bg-muted px-1.5 text-xs font-medium text-muted-foreground">
              {count}
            </span>
          )}
        </div>
      </CardHeader>
      <CardContent>{children}</CardContent>
      {footer !== undefined && (
        <div className="flex justify-end px-3 py-2">{footer}</div>
      )}
    </Card>
  );
}

function InfoRow({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-[11px] uppercase tracking-wider text-subtle-foreground">
        {label}
      </dt>
      <dd className="text-right text-foreground">{value}</dd>
    </div>
  );
}
