// The run's execution trace: every external event the engine journaled for it, oldest first — the
// permanent counterpart of the live delegation tree (which is routing and vanishes on terminal). Each
// row renders from the structured fields, with delegate targets correlated onto the later legs of the
// same delegation, so an ack reads as "← the agent it answers" rather than a bare id. Payload values
// (already secret-redacted by the runtime) expand in place; the raw events are exported as JSON by the
// copy affordance the parent card places next to this list.

import { ChevronDown, ChevronRight } from "lucide-react";
import { useState } from "react";
import type { RunEvent, TreeTarget } from "../../api/types";
import { shortId } from "../../lib/format";
import { Badge, type BadgeTone } from "../ui/Badge";
import { ValueBlock } from "../values/ValueViewer";

const KIND_TONES: Record<RunEvent["kind"], BadgeTone> = {
  delegate: "info",
  delegateAck: "success",
  escalate: "warning",
  escalateAck: "info",
  terminate: "danger",
  terminateAck: "neutral",
};

export function RunTrace({ events, projectId }: { events: RunEvent[]; projectId: string }) {
  const names = targetNames(events);
  return (
    <div className="flex flex-col divide-y divide-edge">
      {events.map((event) => (
        <TraceRow key={event.seq} event={event} names={names} projectId={projectId} />
      ))}
    </div>
  );
}

function TraceRow({
  event,
  names,
  projectId,
}: {
  event: RunEvent;
  names: Map<string, string>;
  projectId: string;
}) {
  const [expanded, setExpanded] = useState(false);
  return (
    <div className="flex flex-col gap-2 py-1.5">
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="font-mono text-xs text-fg-faint" title={event.createdAt}>
          {timeOf(event.createdAt)}
        </span>
        <Badge tone={KIND_TONES[event.kind]}>{event.kind}</Badge>
        <span className="font-mono text-xs text-fg">{describe(event, names)}</span>
        <span className="font-mono text-xs text-fg-faint">
          {event.from}→{event.to}
        </span>
        <span className="font-mono text-xs text-fg-faint" title={event.delegationId}>
          [{shortId(event.delegationId)}
          {event.escalationId === null ? "" : `/${shortId(event.escalationId)}`}]
        </span>
        {event.payload !== null && (
          <button
            type="button"
            onClick={() => setExpanded((current) => !current)}
            className="inline-flex items-center gap-0.5 text-xs text-fg-faint transition-colors hover:text-fg"
          >
            {expanded ? <ChevronDown className="size-3" /> : <ChevronRight className="size-3" />}
            payload
          </button>
        )}
      </div>
      {expanded && event.payload !== null && (
        <div className="border-l border-edge pl-3">
          <ValueBlock value={event.payload} projectId={projectId} />
        </div>
      )}
    </div>
  );
}

/** Delegation → the label of what it summoned, harvested from the trace's own `delegate` events — so
 *  every later leg of the same delegation displays a name instead of an id. */
function targetNames(events: RunEvent[]): Map<string, string> {
  const names = new Map<string, string>();
  for (const event of events) {
    if (event.kind === "delegate" && event.target !== null) {
      names.set(event.delegationId, targetLabel(event.target));
    }
  }
  return names;
}

function describe(event: RunEvent, names: Map<string, string>): string {
  const name = names.get(event.delegationId) ?? shortId(event.delegationId);
  switch (event.kind) {
    case "delegate":
      return `→ ${event.target === null ? name : targetLabel(event.target)}`;
    case "delegateAck":
      return `← ${name}`;
    case "escalate":
      return event.request === null
        ? `${event.ask ?? "ask"} escaped ${name}`
        : `${event.request} — raised under ${name}`;
    case "escalateAck":
      return `answer → ${name}`;
    case "terminate":
      return `cancel ${name}`;
    case "terminateAck":
      return `${name} cancelled`;
  }
}

function targetLabel(target: TreeTarget): string {
  switch (target.kind) {
    case "agent":
      return target.name;
    case "closure":
      return `closure (block ${target.blockId} @ ${target.module})`;
    case "external":
      return target.key;
  }
}

/** The time-of-day slice of an ISO timestamp — the date would repeat on every row (the full stamp is
 *  the row's tooltip). */
function timeOf(timestamp: string): string {
  return timestamp.length >= 19 ? timestamp.slice(11, 19) : timestamp;
}
