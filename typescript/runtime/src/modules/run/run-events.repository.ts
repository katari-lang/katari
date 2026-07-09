// The execution trace of one run — the `run_events` journal, read back as the API presents it. The journal
// row's `event` JSON is the source of truth; this module reads it either as a keyset tail (seq > after) or
// as an offset browse page, and projects each event into a display view: the structured fields a client
// correlates on (delegation / escalation ids, the delegate target, the escalated ask), the redacted payload
// it carried, and a one-line `summary` so a dumb client (the CLI tail) can print the trace without knowing
// the event vocabulary.

import type { Json } from "@katari-lang/types";
import { and, asc, desc, eq, gt, type SQL, sql } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { runEvents } from "../../db/tables/execution.js";
import { countRows, escapeLike } from "../../lib/paging.js";
import { unsealFromStorage } from "../../runtime/actor/seal.js";
import {
  type DelegateTarget,
  type ExternalEvent,
  escalateValue,
  type ReactorName,
} from "../../runtime/event/types.js";
import { valueToJson } from "../../runtime/value/codec.js";
import type { Value } from "../../runtime/value/types.js";
import type { TreeTarget } from "./run-tree.repository.js";

/** One journal row, as the query reads it (the event unsealed like any at-rest payload). */
export interface RunEventRow {
  seq: number;
  event: ExternalEvent;
  createdAt: Date;
}

/** One trace event as the API presents it. `target` is set for a `delegate`; `ask` / `request` for an
 *  `escalate` (`request` only when the ask is one — a panic / throw shows up here by its request name);
 *  `payload` is the redacted value the event carried, `null` when it carries none (terminate legs). */
export interface RunEventView {
  seq: number;
  kind: ExternalEvent["kind"];
  from: ReactorName;
  to: ReactorName;
  delegationId: string;
  escalationId: string | null;
  target: TreeTarget | null;
  ask: string | null;
  request: string | null;
  payload: Json | null;
  summary: string;
  createdAt: Date;
}

/** Project one journal row into its display view (a pure function — the testable heart of the read path).
 *  The user-facing boundary: a secret in a carried value is redacted, never observed. */
export function projectRunEvent(row: RunEventRow): RunEventView {
  const event = row.event;
  const carried = eventValue(event);
  return {
    seq: row.seq,
    kind: event.kind,
    from: event.from,
    to: event.to,
    delegationId: event.delegation,
    escalationId:
      event.kind === "escalate" || event.kind === "escalateAck" ? event.escalation : null,
    target: event.kind === "delegate" ? displayTarget(event.target) : null,
    ask: event.kind === "escalate" ? event.ask.kind : null,
    request: event.kind === "escalate" && event.ask.kind === "request" ? event.ask.request : null,
    payload: carried === null ? null : valueToJson(carried, "redact"),
    summary: summarize(event),
    createdAt: row.createdAt,
  };
}

/** The value an event carries up or down: a delegate's argument, an ack's result, an escalation's carried
 *  value (a request argument or a control escape's value). The terminate legs carry none. */
function eventValue(event: ExternalEvent): Value | null {
  switch (event.kind) {
    case "delegate":
      return event.argument;
    case "delegateAck":
      return event.value;
    case "escalate":
      return escalateValue(event.ask);
    case "escalateAck":
      return event.value;
    case "terminate":
    case "terminateAck":
      return null;
  }
}

/** Project a delegate target to the same display shape the run tree uses. */
function displayTarget(target: DelegateTarget): TreeTarget {
  switch (target.kind) {
    case "named":
      return { kind: "agent", name: target.name };
    case "closure":
      return { kind: "closure", blockId: target.blockId, module: target.module };
    case "external":
      return { kind: "external", key: target.key };
  }
}

/** One human line per event. Ids are shortened to a correlatable prefix — a reader matches an ack to its
 *  delegate by the `[delegation]` (and an answer to its question by the `[delegation/escalation]`) prefix,
 *  the way the lines of a distributed trace correlate. */
function summarize(event: ExternalEvent): string {
  const route = `${event.from}→${event.to}`;
  const delegation = shortId(event.delegation);
  switch (event.kind) {
    case "delegate":
      return `delegate ${route} ${targetLabel(event.target)} [${delegation}]`;
    case "delegateAck":
      return `delegateAck ${route} [${delegation}]`;
    case "escalate": {
      const what = event.ask.kind === "request" ? `request ${event.ask.request}` : event.ask.kind;
      return `escalate ${route} ${what} [${delegation}/${shortId(event.escalation)}]`;
    }
    case "escalateAck":
      return `escalateAck ${route} [${delegation}/${shortId(event.escalation)}]`;
    case "terminate":
      return `terminate ${route} [${delegation}]`;
    case "terminateAck":
      return `terminateAck ${route} [${delegation}]`;
  }
}

function targetLabel(target: DelegateTarget): string {
  switch (target.kind) {
    case "named":
      return String(target.name);
    case "closure":
      return `closure (block ${target.blockId} @ ${target.module})`;
    case "external":
      return `external ${target.key}`;
  }
}

function shortId(id: string): string {
  return id.slice(0, 8);
}

/** How one trace page is positioned — a genuine sum, decided once by the service from the query:
 *  `tail` is the keyset cursor (rows strictly after `after`) a watcher / the CLI polls with; `browse`
 *  is the console's offset pager. Keeping the modes apart keeps the hot tail free of the count query
 *  only the pager needs. */
export type TraceCursor = { mode: "tail"; after: number } | { mode: "browse"; offset: number };

/** The cursor-independent half of a trace query: `kind` / `search` narrow the set, `order` is the seq
 *  direction (default oldest-first), `limit` bounds the page. */
export interface TraceFilter {
  limit: number;
  kind?: ExternalEvent["kind"];
  search?: string;
  order?: "asc" | "desc";
}

export interface RunEventsPage {
  rows: RunEventRow[];
  total: number;
}

/** The `kind` / `search` predicates shared by the page query and the count — everything but the paging
 *  cursor. `search` is a case-insensitive substring over the event JSON rendered to text: it matches the
 *  ids, reactor names, delegate targets, request names, and any public payload text, but never a sealed
 *  private value (which is opaque ciphertext at rest). */
function filterConditions(projectId: string, runId: string, filter: TraceFilter): SQL[] {
  const conditions: SQL[] = [eq(runEvents.projectId, projectId), eq(runEvents.runId, runId)];
  if (filter.kind !== undefined) {
    conditions.push(sql`${runEvents.event} ->> 'kind' = ${filter.kind}`);
  }
  if (filter.search !== undefined) {
    conditions.push(sql`${runEvents.event}::text ILIKE ${`%${escapeLike(filter.search)}%`}`);
  }
  return conditions;
}

/** The page select both modes share: the projection, the filter, the seq order, and the page bound. */
function selectTracePage(executor: Executor, conditions: SQL[], filter: TraceFilter) {
  const direction = filter.order === "desc" ? desc : asc;
  return executor
    .select({ seq: runEvents.seq, event: runEvents.event, createdAt: runEvents.createdAt })
    .from(runEvents)
    .where(and(...conditions))
    .orderBy(direction(runEvents.seq))
    .limit(filter.limit);
}

/** Undo the at-rest seal on a journal row's event (sealed like any stored payload). */
function unsealRunEventRow(row: RunEventRow): RunEventRow {
  return { seq: row.seq, event: unsealFromStorage(row.event), createdAt: row.createdAt };
}

export const runEventsRepository = {
  /** The keyset tail of a run's trace: the filtered rows strictly after `after`, in `order`. This is the
   *  hot polling path (a watcher / the CLI streams it), so no total is computed here — a count per poll
   *  would rescan the whole run each time, and the tail never reads it. The caller scopes the run to its
   *  project first, like the escalation audit. */
  async tail(
    executor: Executor,
    projectId: string,
    runId: string,
    after: number,
    filter: TraceFilter,
  ): Promise<RunEventRow[]> {
    const conditions = [...filterConditions(projectId, runId, filter), gt(runEvents.seq, after)];
    const rows = await selectTracePage(executor, conditions, filter);
    return rows.map(unsealRunEventRow);
  },

  /** One browse page of a run's trace: the `offset`-th slice of the filtered set, plus the whole set's
   *  `total` (the cursor ignored) so the console can size its pager. */
  async browse(
    executor: Executor,
    projectId: string,
    runId: string,
    offset: number,
    filter: TraceFilter,
  ): Promise<RunEventsPage> {
    const conditions = filterConditions(projectId, runId, filter);
    const rows = await selectTracePage(executor, conditions, filter).offset(offset);
    const total = await countRows(executor, runEvents, and(...conditions));
    return { rows: rows.map(unsealRunEventRow), total };
  },
};
