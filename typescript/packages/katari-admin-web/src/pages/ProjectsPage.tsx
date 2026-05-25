import { Link } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Folder, FolderOpen } from "lucide-react";
import { useApiClient } from "@/contexts/ApiKeyContext";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { Card, CardHeader, CardTitle } from "@/components/ui/Card";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { EmptyState } from "@/components/ui/EmptyState";

export function ProjectsPage() {
  const client = useApiClient();
  const { data, isLoading, isError, error } = useQuery({
    queryKey: ["projects"],
    queryFn: () => client.listProjects({ limit: 200 }),
  });

  return (
    <div>
      <PageHeader title="Projects" description="Manage your projects" />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error
              ? error.message
              : "Failed to load projects."}
          </p>
        )}
        {!isLoading && !isError && data !== undefined && (
          <>
            {data.projects.length === 0 ? (
              <EmptyState
                icon={Folder}
                title="No projects yet"
                description={
                  <>
                    Run{" "}
                    <code className="font-mono text-foreground">
                      katari apply
                    </code>{" "}
                    to publish a snapshot — the project will appear here.
                  </>
                }
              />
            ) : (
              <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {data.projects.map((p, idx) => (
                  <motion.li
                    key={p.id}
                    initial={{ opacity: 0, y: 4 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 0.2, delay: idx * 0.03 }}
                  >
                    <Link to={`/project/${p.id}`} className="block">
                      <Card className="transition-all hover:border-border-strong hover:bg-muted">
                        <CardHeader>
                          <CardTitle className="truncate py-1">
                            {p.name}
                          </CardTitle>
                          {p.description !== null && (
                            <p className="line-clamp-2 text-xs text-subtle-foreground">
                              {p.description}
                            </p>
                          )}
                        </CardHeader>
                      </Card>
                    </Link>
                  </motion.li>
                ))}
              </ul>
            )}
          </>
        )}
      </PageContent>
    </div>
  );
}
