import { useQuery } from "@tanstack/react-query";
import { useApiClient } from "@/contexts/ApiKeyContext";
import type { ProjectId, SnapshotId } from "@/api/types";

/**
 * Fetches the project's snapshot list (shared react-query cache key) and
 * exposes a lookup from snapshot id to its human-readable `message`.
 *
 * Returns `undefined` for a given id while the list is still loading or
 * when no snapshot with that id exists.
 */
export function useSnapshotMessage(
  projectId: string | undefined,
): {
  /** Look up a single snapshot's message by id. */
  getMessage: (snapshotId: SnapshotId | undefined) => string | undefined;
} {
  const client = useApiClient();

  const snapshotsQ = useQuery({
    queryKey: ["snapshots", projectId],
    queryFn: () =>
      client.listSnapshots(projectId as ProjectId, { limit: 200 }),
    enabled: typeof projectId === "string",
  });

  const messageById = new Map(
    (snapshotsQ.data?.snapshots ?? []).map((s) => [s.id, s.message]),
  );

  function getMessage(
    snapshotId: SnapshotId | undefined,
  ): string | undefined {
    if (snapshotId === undefined) return undefined;
    return messageById.get(snapshotId);
  }

  return { getMessage };
}
