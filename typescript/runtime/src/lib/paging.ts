// Shared plumbing for the paged list endpoints (runs / snapshots / files / the trace browse): the LIKE
// escaping, the optional limit/offset window, and the filtered-set count the pager needs. Each repository
// keeps its own columns and conditions and delegates only this mechanical part, so the lists cannot drift
// apart in how they page.

import { type SQL, sql } from "drizzle-orm";
import type { PgTable } from "drizzle-orm/pg-core";
import type { Executor } from "../db/client.js";

/** Escape a user substring for a LIKE pattern: the wildcards (`%` / `_`) and the escape character itself
 *  become literals, so a search for "50%" matches the text "50%" rather than "50<anything>". */
export function escapeLike(term: string): string {
  return term.replace(/[\\%_]/g, (character) => `\\${character}`);
}

/** An optional page window over a list. Both bounds omitted selects the whole filtered set — the CLI's
 *  unbounded lists and the console's snapshot selector rely on that. */
export interface PageWindow {
  limit?: number;
  offset?: number;
}

/** The slice of a Drizzle select builder the window applier needs, kept structural so one applier serves
 *  every table's projection (the concrete builder types differ per table and per already-applied step). */
export interface PageableQuery<Row> extends PromiseLike<Row[]> {
  limit(count: number): OffsettableQuery<Row>;
  offset(count: number): PromiseLike<Row[]>;
}

interface OffsettableQuery<Row> extends PromiseLike<Row[]> {
  offset(count: number): PromiseLike<Row[]>;
}

/** Apply an optional `limit` / `offset` window to a built list query and run it. */
export function applyPageWindow<Row>(
  query: PageableQuery<Row>,
  window: PageWindow,
): Promise<Row[]> {
  const limited = window.limit === undefined ? query : query.limit(window.limit);
  return Promise.resolve(window.offset === undefined ? limited : limited.offset(window.offset));
}

/** Count the rows a filter matches — the `total` a paged list advertises for the console's pager. */
export function countRows(
  executor: Executor,
  table: PgTable,
  where: SQL | undefined,
): Promise<number> {
  return executor
    .select({ value: sql<number>`count(*)::int` })
    .from(table)
    .where(where)
    .then(([row]) => row?.value ?? 0);
}

/** Run a built list query under its window and pair the page with the filtered set's `total`. An
 *  unwindowed list already IS the whole filtered set, so its own length serves as the total and the
 *  count query is skipped (the CLI's unbounded lists take this path on every call). */
export async function listPageWithTotal<Row>(options: {
  executor: Executor;
  query: PageableQuery<Row>;
  window: PageWindow;
  table: PgTable;
  where: SQL | undefined;
}): Promise<{ rows: Row[]; total: number }> {
  const rows = await applyPageWindow(options.query, options.window);
  const total =
    options.window.limit === undefined && options.window.offset === undefined
      ? rows.length
      : await countRows(options.executor, options.table, options.where);
  return { rows, total };
}
