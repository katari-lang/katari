import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { KeyRound, Pencil, Plus, ShieldCheck, Trash2 } from "lucide-react";
import { useState } from "react";
import type { EnvEntry } from "@/api/types";
import { EnvDeleteDialog } from "@/components/domain/EnvDeleteDialog";
import { EnvUpsertDialog } from "@/components/domain/EnvUpsertDialog";
import { Badge } from "@/components/ui/Badge";
import { Button } from "@/components/ui/Button";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { Table, TBody, TD, TH, THead, TR } from "@/components/ui/Table";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { formatDateTime, relativeTime } from "@/lib/format";
import { useCurrentProjectId } from "@/lib/useCurrentProjectId";

export function EnvPage() {
  const client = useApiClient();
  const projectId = useCurrentProjectId();
  const [upserting, setUpserting] = useState<EnvEntry | "new" | null>(null);
  const [deleting, setDeleting] = useState<EnvEntry | null>(null);

  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["env", projectId],
    queryFn: () => client.listEnv(projectId!),
    enabled: projectId !== null,
  });

  return (
    <div>
      <PageHeader
        title="Environment"
        description="Per-project key-value store"
        docs={{ slug: "concepts/env", title: "About the env store" }}
        actions={
          <Button onClick={() => setUpserting("new")}>
            <Plus className="size-4" />
            Add entry
          </Button>
        }
      />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load env."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            transition={{ duration: 0.15 }}
          >
            {data.entries.length === 0 ? (
              <EmptyState
                icon={KeyRound}
                title="No env entries"
                action={
                  <Button variant="primary" onClick={() => setUpserting("new")}>
                    <Plus className="size-4" />
                    Add entry
                  </Button>
                }
              />
            ) : (
              <Table>
                <THead>
                  <TR>
                    <TH>Key</TH>
                    <TH>Value</TH>
                    <TH>Updated</TH>
                    <TH className="text-right">Actions</TH>
                  </TR>
                </THead>
                <TBody>
                  {data.entries.map((entry) => (
                    <TR key={entry.key}>
                      <TD>
                        <div className="flex items-center gap-2">
                          <span className="font-mono text-foreground">{entry.key}</span>
                          {entry.isSecret && (
                            <Badge tone="warning">
                              <ShieldCheck className="size-3" />
                              secret
                            </Badge>
                          )}
                        </div>
                      </TD>
                      <TD>
                        {entry.isSecret ? (
                          <code className="font-mono text-xs text-subtle-foreground">
                            {entry.value}
                          </code>
                        ) : (
                          <code className="font-mono text-xs text-foreground break-all">
                            {entry.value}
                          </code>
                        )}
                      </TD>
                      <TD
                        className="text-xs text-muted-foreground"
                        title={formatDateTime(entry.updatedAt)}
                      >
                        {relativeTime(entry.updatedAt)}
                      </TD>
                      <TD>
                        <div className="flex justify-end gap-1">
                          <button
                            type="button"
                            onClick={() => setUpserting(entry)}
                            className="inline-flex h-8 w-8 items-center justify-center  text-muted-foreground transition-colors hover:bg-muted hover:text-foreground hover:cursor-pointer"
                            aria-label={`Edit ${entry.key}`}
                          >
                            <Pencil className="size-4" />
                          </button>
                          <button
                            type="button"
                            onClick={() => setDeleting(entry)}
                            className="inline-flex h-8 w-8 items-center justify-center  text-muted-foreground transition-colors hover:bg-danger/10 hover:text-danger hover:cursor-pointer"
                            aria-label={`Delete ${entry.key}`}
                          >
                            <Trash2 className="size-4" />
                          </button>
                        </div>
                      </TD>
                    </TR>
                  ))}
                </TBody>
              </Table>
            )}
          </motion.div>
        )}
      </PageContent>
      {projectId !== null && (
        <>
          <EnvUpsertDialog
            projectId={projectId}
            open={upserting !== null}
            onClose={() => setUpserting(null)}
            editing={upserting === "new" || upserting === null ? null : upserting}
          />
          <EnvDeleteDialog
            projectId={projectId}
            open={deleting !== null}
            onClose={() => setDeleting(null)}
            target={deleting}
          />
        </>
      )}
    </div>
  );
}
