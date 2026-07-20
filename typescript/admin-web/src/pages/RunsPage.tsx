import { Play, Search, X } from "lucide-react";
import { useEffect, useState } from "react";
import { Link, useParams, useSearchParams } from "react-router-dom";
import { useRuns } from "../api/queries";
import type { RunState } from "../api/types";
import { RunsTable } from "../components/runs/RunsTable";
import { Button } from "../components/ui/Button";
import { Card } from "../components/ui/Card";
import { EmptyState } from "../components/ui/EmptyState";
import { Input } from "../components/ui/Field";
import { PageHeader } from "../components/ui/PageHeader";
import { Pagination } from "../components/ui/Pagination";
import { LoadingBlock } from "../components/ui/Spinner";
import { cn } from "../lib/cn";

const PAGE_SIZE = 50;

const filters: Array<{ label: string; state: RunState | undefined }> = [
  { label: "All", state: undefined },
  { label: "Running", state: "running" },
  { label: "Done", state: "done" },
  { label: "Error", state: "error" },
  { label: "Cancelled", state: "cancelled" },
];

function useDebounced<T>(value: T, delayMilliseconds: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMilliseconds);
    return () => clearTimeout(timer);
  }, [value, delayMilliseconds]);
  return debounced;
}

export function RunsPage() {
  const { projectId = "" } = useParams();
  const [searchParams, setSearchParams] = useSearchParams();
  const stateParam = searchParams.get("state") as RunState | null;
  const [searchInput, setSearchInput] = useState("");
  const [offset, setOffset] = useState(0);
  const search = useDebounced(searchInput.trim(), 300);

  // A new filter / search points at a different (or shorter) result set, so page back to the start.
  // biome-ignore lint/correctness/useExhaustiveDependencies: reset the page when the query shape changes
  useEffect(() => setOffset(0), [stateParam, search]);

  const runs = useRuns(projectId, {
    limit: PAGE_SIZE,
    offset,
    ...(stateParam === null ? {} : { state: stateParam }),
    ...(search === "" ? {} : { search }),
  });

  const items = runs.data?.items ?? [];
  const total = runs.data?.total ?? 0;
  const filtersActive = search !== "" || stateParam !== null;

  return (
    <>
      <PageHeader
        title="Runs"
        description="Agent activations, newest first."
        actions={
          <div className="flex items-center border border-edge">
            {filters.map(({ label, state }) => (
              <button
                key={label}
                type="button"
                onClick={() => setSearchParams(state === undefined ? {} : { state })}
                className={cn(
                  "px-2.5 py-1 text-xs text-fg-muted transition-colors hover:text-fg",
                  stateParam === (state ?? null) && "bg-sunken font-medium text-fg",
                )}
              >
                {label}
              </button>
            ))}
          </div>
        }
      />

      <div className="flex flex-col gap-3">
        <div className="relative max-w-md">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-fg-faint" />
          <Input
            value={searchInput}
            onChange={(event) => setSearchInput(event.target.value)}
            placeholder="Search runs by name, agent, or id"
            className="pl-8"
          />
          {searchInput !== "" && (
            <button
              type="button"
              onClick={() => setSearchInput("")}
              aria-label="Clear search"
              className="absolute top-1/2 right-2 -translate-y-1/2 text-fg-faint hover:text-fg"
            >
              <X className="size-3.5" />
            </button>
          )}
        </div>

        {runs.isPending ? (
          <LoadingBlock />
        ) : items.length === 0 ? (
          filtersActive ? (
            <EmptyState icon={Search} title="No runs match" description="Try a different filter." />
          ) : (
            <EmptyState
              icon={Play}
              title="No runs"
              description="Invoke an agent to start one."
              action={
                <Link to={`/projects/${projectId}/agents`}>
                  <Button>Browse agents</Button>
                </Link>
              }
            />
          )
        ) : (
          <>
            <Card>
              <RunsTable projectId={projectId} runs={items} />
            </Card>
            <Pagination
              offset={offset}
              limit={PAGE_SIZE}
              total={total}
              onOffset={setOffset}
              unit="runs"
            />
          </>
        )}
      </div>
    </>
  );
}
