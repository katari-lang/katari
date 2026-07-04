import { useNavigate } from "react-router-dom";
import type { Run } from "../../api/types";
import { formatDateTime, relativeTime } from "../../lib/format";
import { CopyableId } from "../ui/Copy";
import { Cell, Row, Table } from "../ui/Table";
import { RunStateBadge } from "./RunStateBadge";

export function RunsTable({ projectId, runs }: { projectId: string; runs: Run[] }) {
  const navigate = useNavigate();
  return (
    <Table headers={["State", "Run", "Agent", "Started", "Finished", "Id"]}>
      {runs.map((run) => (
        <Row key={run.id} onClick={() => navigate(`/projects/${projectId}/runs/${run.id}`)}>
          <Cell>
            <RunStateBadge state={run.state} />
          </Cell>
          <Cell className="font-medium text-fg">{run.name}</Cell>
          <Cell className="font-mono text-xs">{run.qualifiedName}</Cell>
          <Cell>
            <span title={formatDateTime(run.createdAt)} className="text-fg-muted">
              {relativeTime(run.createdAt)}
            </span>
          </Cell>
          <Cell>
            {run.completedAt !== null && (
              <span title={formatDateTime(run.completedAt)} className="text-fg-muted">
                {relativeTime(run.completedAt)}
              </span>
            )}
          </Cell>
          <Cell>
            <CopyableId id={run.id} />
          </Cell>
        </Row>
      ))}
    </Table>
  );
}
