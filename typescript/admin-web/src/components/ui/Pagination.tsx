// Offset pager shared by every paged listing (runs, snapshots, files, the run trace). It owns only the
// arithmetic — "X–Y of Z" and which of First/Prev/Next/Last are reachable — and reports the new offset;
// the page keeps the offset in its own state (or the URL) and refetches.

import { ChevronFirst, ChevronLast, ChevronLeft, ChevronRight } from "lucide-react";
import { Button } from "./Button";

export function Pagination({
  offset,
  limit,
  total,
  onOffset,
  unit = "items",
}: {
  offset: number;
  limit: number;
  total: number;
  onOffset: (next: number) => void;
  unit?: string;
}) {
  const from = total === 0 ? 0 : offset + 1;
  const to = Math.min(offset + limit, total);
  const atStart = offset <= 0;
  const atEnd = offset + limit >= total;
  // The offset of the last page: the largest multiple of `limit` that still holds a row.
  const lastOffset = total === 0 ? 0 : Math.floor((total - 1) / limit) * limit;

  return (
    <div className="flex flex-wrap items-center justify-between gap-2 text-xs text-fg-faint">
      <span>{total === 0 ? `No ${unit}` : `${from}–${to} of ${total} ${unit}`}</span>
      <div className="flex items-center gap-1">
        <Button size="sm" variant="ghost" disabled={atStart} onClick={() => onOffset(0)}>
          <ChevronFirst className="size-3.5" />
        </Button>
        <Button
          size="sm"
          variant="ghost"
          disabled={atStart}
          onClick={() => onOffset(Math.max(0, offset - limit))}
        >
          <ChevronLeft className="size-3.5" /> Prev
        </Button>
        <Button size="sm" variant="ghost" disabled={atEnd} onClick={() => onOffset(offset + limit)}>
          Next <ChevronRight className="size-3.5" />
        </Button>
        <Button size="sm" variant="ghost" disabled={atEnd} onClick={() => onOffset(lastOffset)}>
          <ChevronLast className="size-3.5" />
        </Button>
      </div>
    </div>
  );
}
