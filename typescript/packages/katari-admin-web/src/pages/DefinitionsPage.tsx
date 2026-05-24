import { useMemo, useState } from "react";
import { useParams, useSearchParams } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Boxes } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";
import { DefinitionsSnapshotPicker } from "@/components/domain/DefinitionsSnapshotPicker";
import { DefinitionsTree } from "@/components/domain/DefinitionsTree";
import type { ProjectId, SnapshotId } from "@/api/types";

export function DefinitionsPage() {
  const { projectId } = useParams<{ projectId: string }>();
  const [params, setParams] = useSearchParams();
  const client = useApiClient();

  const snapshotParam = params.get("snapshot");
  const selected: SnapshotId | null =
    snapshotParam === null || snapshotParam === "latest"
      ? null
      : (snapshotParam as SnapshotId);

  // Project name is used as a qualified-name prefix filter so the tree
  // defaults to "what this project actually defines". stdlib (`prim.*`)
  // and library entries flow through the same schema bundle now (= the
  // compiler emits everything uniformly), so admin has to do the
  // display-time filtering itself.
  const projectQ = useQuery({
    queryKey: ["project", projectId],
    queryFn: () => client.getProject(projectId as ProjectId),
    enabled: typeof projectId === "string",
  });
  const projectName = projectQ.data?.project.name;

  const [showAll, setShowAll] = useState(false);

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["definitions", projectId, selected ?? "latest"],
    queryFn: () =>
      client.listAgentDefinitions({
        projectId: projectId as ProjectId,
        snapshotId: selected ?? undefined,
      }),
    enabled: typeof projectId === "string",
  });

  const visibleDefinitions = useMemo(() => {
    if (data === undefined) return [];
    if (showAll || projectName === undefined) return data.definitions;
    const prefix = `${projectName}.`;
    return data.definitions.filter((d) => d.qualifiedName.startsWith(prefix));
  }, [data, showAll, projectName]);

  function setSelected(next: SnapshotId | null) {
    if (next === null) {
      params.delete("snapshot");
    } else {
      params.set("snapshot", next);
    }
    setParams(params);
  }

  const hiddenCount = data === undefined ? 0 : data.definitions.length - visibleDefinitions.length;

  return (
    <div>
      <PageHeader
        title="Definitions"
        description="Callable agents in the selected snapshot. Pick one to invoke it with a generated form."
      />
      <PageContent>
        {/* Snapshot picker + show-all toggle: both scope the tree below, so
            they sit immediately above it instead of in the right-aligned
            header actions area. */}
        {typeof projectId === "string" && (
          <div className="mb-4 flex items-center justify-between gap-2">
            <DefinitionsSnapshotPicker
              projectId={projectId as ProjectId}
              selected={selected}
              resolvedId={data?.snapshotId ?? null}
              onSelect={setSelected}
            />
            <label className="inline-flex cursor-pointer items-center gap-2 text-xs text-muted-foreground">
              <input
                type="checkbox"
                checked={showAll}
                onChange={(e) => setShowAll(e.target.checked)}
                className="accent-accent"
              />
              <span>
                Show stdlib &amp; libraries
                {hiddenCount > 0 && !showAll && (
                  <span className="ml-1 text-subtle-foreground">({hiddenCount} hidden)</span>
                )}
              </span>
            </label>
          </div>
        )}
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className="border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load definitions."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {visibleDefinitions.length === 0 ? (
              <EmptyState
                icon={Boxes}
                title={
                  data.definitions.length === 0
                    ? "No definitions in this snapshot"
                    : "No project definitions"
                }
                description={
                  data.definitions.length === 0
                    ? "Publish a snapshot with at least one agent declaration to populate this list."
                    : `Toggle "Show stdlib & libraries" above to see the ${data.definitions.length} entries from other packages.`
                }
              />
            ) : (
              <div className="border border-border">
                <DefinitionsTree
                  definitions={visibleDefinitions}
                  href={(def) => {
                    const search = selected === null ? "" : `?snapshot=${selected}`;
                    return `/project/${projectId}/definitions/${encodeURIComponent(
                      def.qualifiedName,
                    )}${search}`;
                  }}
                />
              </div>
            )}
          </motion.div>
        )}
      </PageContent>
    </div>
  );
}
