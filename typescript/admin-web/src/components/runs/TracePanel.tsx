// The run's execution trace with its own search, kind filter, order, and offset pager — the debugger
// surface. A long trace no longer truncates to a first page: the pager walks the whole journal, and the
// search box narrows it server-side (a case-insensitive substring over each event — its ids, delegate
// targets, request names, and any public payload text; sealed private values never match). The panel
// owns its query state and hides itself entirely for a run that has produced no events and has no active
// filter, so it stays invisible until there is something to show.

import { ArrowDownWideNarrow, ArrowUpWideNarrow, Search, X } from "lucide-react";
import { useEffect, useState } from "react";
import { useRunEvents } from "../../api/queries";
import { RUN_EVENT_KINDS, type RunEvent } from "../../api/types";
import { Card, CardBody, CardHeader } from "../ui/Card";
import { CopyButton } from "../ui/Copy";
import { Input, Select } from "../ui/Field";
import { Pagination } from "../ui/Pagination";
import { RunTrace } from "./RunTrace";

const PAGE_SIZE = 100;

/** Debounce a fast-changing value (the search box) so a keystroke does not fire a request per character. */
function useDebounced<T>(value: T, delayMilliseconds: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delayMilliseconds);
    return () => clearTimeout(timer);
  }, [value, delayMilliseconds]);
  return debounced;
}

export function TracePanel({
  projectId,
  runId,
  live,
}: {
  projectId: string;
  runId: string;
  live: boolean;
}) {
  const [searchInput, setSearchInput] = useState("");
  const [kind, setKind] = useState<RunEvent["kind"] | "">("");
  // Newest-first by default: when a trace is long, the recent events are what a debugger reaches for, and
  // a live run's new events then land at the top of page one.
  const [order, setOrder] = useState<"asc" | "desc">("desc");
  const [offset, setOffset] = useState(0);

  const search = useDebounced(searchInput.trim(), 300);
  const filtersActive = search !== "" || kind !== "";

  // Any filter / order change re-pages from the start — the previous offset would point into a different
  // (or shorter) result set.
  // biome-ignore lint/correctness/useExhaustiveDependencies: reset the page when the query shape changes
  useEffect(() => setOffset(0), [search, kind, order]);

  const trace = useRunEvents(
    projectId,
    runId,
    {
      offset,
      limit: PAGE_SIZE,
      order,
      ...(kind === "" ? {} : { kind }),
      ...(search === "" ? {} : { search }),
    },
    live,
  );

  const events = trace.data?.events ?? [];
  const total = trace.data?.total ?? 0;

  // Nothing to show and nothing being filtered: stay invisible (a just-started run, an empty trace). Once
  // a filter is active the panel stays up even at zero matches, so the filter can be cleared.
  if (trace.data === undefined || (total === 0 && !filtersActive)) return null;

  return (
    <Card>
      <CardHeader
        title="Trace"
        actions={
          <CopyButton value={JSON.stringify(events, null, 2)} label="Copy this page as JSON" />
        }
      />
      <CardBody className="flex flex-col gap-3">
        <div className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-48 flex-1">
            <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-fg-faint" />
            <Input
              value={searchInput}
              onChange={(event) => setSearchInput(event.target.value)}
              placeholder="Search events (ids, targets, requests, payloads…)"
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
          <Select
            aria-label="Event kind"
            className="w-40"
            value={kind}
            onChange={(event) => setKind(event.target.value as RunEvent["kind"] | "")}
          >
            <option value="">All kinds</option>
            {RUN_EVENT_KINDS.map((eventKind) => (
              <option key={eventKind} value={eventKind}>
                {eventKind}
              </option>
            ))}
          </Select>
          <button
            type="button"
            onClick={() => setOrder((current) => (current === "desc" ? "asc" : "desc"))}
            className="inline-flex items-center gap-1.5 border border-edge-strong px-2.5 py-1.5 text-xs text-fg-muted transition-colors hover:text-fg"
            title="Toggle event order"
          >
            {order === "desc" ? (
              <ArrowDownWideNarrow className="size-3.5" />
            ) : (
              <ArrowUpWideNarrow className="size-3.5" />
            )}
            {order === "desc" ? "Newest first" : "Oldest first"}
          </button>
        </div>

        <Pagination
          offset={offset}
          limit={PAGE_SIZE}
          total={total}
          onOffset={setOffset}
          unit="events"
        />

        {events.length === 0 ? (
          <p className="py-6 text-center text-sm text-fg-faint">No events match this filter.</p>
        ) : (
          <div className="overflow-x-auto">
            <RunTrace events={events} projectId={projectId} />
          </div>
        )}
      </CardBody>
    </Card>
  );
}
