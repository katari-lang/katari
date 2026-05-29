import { useInfiniteQuery } from "@tanstack/react-query";
import { motion } from "framer-motion";
import { Folder } from "lucide-react";
import { Link } from "react-router-dom";
import { Button } from "@/components/ui/Button";
import { Card, CardHeader, CardTitle } from "@/components/ui/Card";
import { EmptyState } from "@/components/ui/EmptyState";
import { PageContent, PageHeader } from "@/components/ui/PageHeader";
import { SpinnerOverlay } from "@/components/ui/Spinner";
import { useApiClient } from "@/contexts/ApiKeyContext";

const PAGE_SIZE = 50;

export function ProjectsPage() {
  const client = useApiClient();
  const { data, isLoading, isError, error, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useInfiniteQuery({
      queryKey: ["projects", "infinite"],
      queryFn: ({ pageParam }) =>
        client.listProjects({
          limit: PAGE_SIZE,
          cursor: pageParam ?? undefined,
        }),
      initialPageParam: null as string | null,
      getNextPageParam: (lastPage) => lastPage.nextCursor,
    });

  const projects = data?.pages.flatMap((p) => p.projects) ?? [];

  return (
    <div>
      <PageHeader title="Projects" />
      <PageContent>
        {isLoading && <SpinnerOverlay />}
        {isError && (
          <p className=" border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error instanceof Error ? error.message : "Failed to load projects."}
          </p>
        )}
        {!isLoading &&
          !isError &&
          data !== undefined &&
          (projects.length === 0 ? (
            <EmptyState
              icon={Folder}
              title="No projects yet"
              description={
                <>
                  Run <code className="font-mono text-foreground">katari apply</code> to publish
                  your first snapshot.
                </>
              }
            />
          ) : (
            <>
              <ul className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
                {projects.map((p, idx) => (
                  <motion.li
                    key={p.id}
                    initial={{ opacity: 0, y: 4 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ duration: 0.2, delay: idx * 0.03 }}
                  >
                    <Link to={`/project/${p.id}`} className="block">
                      <Card className="transition-all hover:border-border-strong hover:bg-muted">
                        <CardHeader>
                          <CardTitle className="truncate py-1">{p.name}</CardTitle>
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
              {hasNextPage && (
                <div className="mt-4 flex justify-center">
                  <Button
                    variant="secondary"
                    size="sm"
                    loading={isFetchingNextPage}
                    onClick={() => fetchNextPage()}
                  >
                    Load more
                  </Button>
                </div>
              )}
            </>
          ))}
      </PageContent>
    </div>
  );
}
