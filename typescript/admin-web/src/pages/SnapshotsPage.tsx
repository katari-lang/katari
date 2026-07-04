// Deploy history: every snapshot with its message and module manifest; the head is marked. Runs
// pin the snapshot they started on, so old versions remain inspectable here.

import { Camera } from "lucide-react";
import { Link, useParams } from "react-router-dom";
import { useHeadSnapshot, useSnapshots } from "../api/queries";
import { Badge } from "../components/ui/Badge";
import { Card, CardBody, CardHeader } from "../components/ui/Card";
import { CopyableId } from "../components/ui/Copy";
import { EmptyState } from "../components/ui/EmptyState";
import { PageHeader } from "../components/ui/PageHeader";
import { LoadingBlock } from "../components/ui/Spinner";
import { formatDateTime, shortId } from "../lib/format";

export function SnapshotsPage() {
  const { projectId = "" } = useParams();
  const snapshots = useSnapshots(projectId);
  const head = useHeadSnapshot(projectId);

  const ordered = [...(snapshots.data ?? [])].sort(
    (left, right) => new Date(right.createdAt).getTime() - new Date(left.createdAt).getTime(),
  );

  return (
    <>
      <PageHeader title="Snapshots" description="Deploys, newest first. `katari apply` adds one." />
      {snapshots.isPending ? (
        <LoadingBlock />
      ) : ordered.length === 0 ? (
        <EmptyState
          icon={Camera}
          title="No deploys yet"
          description="Run `katari apply` from your project directory to publish a first snapshot."
        />
      ) : (
        <div className="flex flex-col gap-4">
          {ordered.map((snapshot) => (
            <Card key={snapshot.id}>
              <CardHeader
                title={
                  <span className="inline-flex items-center gap-2">
                    {snapshot.message}
                    {snapshot.id === head.data?.id && <Badge tone="success">head</Badge>}
                  </span>
                }
                actions={
                  <span className="flex items-center gap-2 text-xs text-fg-faint">
                    {formatDateTime(snapshot.createdAt)}
                    <Link
                      to={`/projects/${projectId}/agents?snapshot=${snapshot.id}`}
                      className="text-accent hover:underline"
                    >
                      agents
                    </Link>
                    <CopyableId id={snapshot.id} />
                  </span>
                }
              />
              {/* The list rows are summaries; the module manifest is only known for the head. */}
              {snapshot.id === head.data?.id && Object.keys(head.data.modules).length > 0 && (
                <CardBody className="flex flex-wrap gap-x-6 gap-y-1">
                  {Object.entries(head.data.modules).map(([moduleName, hash]) => (
                    <span key={moduleName} className="font-mono text-xs text-fg-muted" title={hash}>
                      {moduleName}
                      <span className="text-fg-faint"> @ {shortId(hash)}</span>
                    </span>
                  ))}
                </CardBody>
              )}
            </Card>
          ))}
        </div>
      )}
    </>
  );
}
