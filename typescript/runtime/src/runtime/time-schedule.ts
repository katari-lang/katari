// The durable shape of a `time` call's work — a leaf module (it imports only value / id leaves) so both the
// `time_instances` table (`$type` on its `operation` column) and the `TimeReactor` share one definition with
// no actor↔db import cycle.
//
// A `time` call is a three-way sum decided ONCE, at the reactor's `openPayload` boundary, from which compiled
// `prelude.time.*` external the delegate names: `now` (resolve with the current instant), `sleep` (resolve
// with `null` at an absolute deadline — both `sleep` and `sleep_until` collapse to this one absolute deadline
// here), or `watch` (fire `deliverTo` once per schedule occurrence, forever). Every lifecycle method then
// dispatches that sum structurally, never a field sniff.

import type { SnapshotId } from "./ids.js";
import type { Value } from "./value/types.js";

/** When a `watch`'s occurrences fall. `interval` fires every `milliseconds` after the watch starts (phase
 *  anchored to the start); `cron` fires at the occurrences of a standard cron `expression` read in an IANA
 *  `timezone` (5-field, or 6-field with a leading seconds field). */
export type Schedule =
  | { kind: "interval"; milliseconds: number }
  | { kind: "cron"; expression: string; timezone: string };

/** What a `time` call does — the sum the reactor decides ONCE at `openPayload` and every lifecycle method
 *  dispatches structurally. `sleep`'s `deadline` is absolute epoch milliseconds (a relative `sleep(ms)` is
 *  resolved to `now + ms` at open, so recovery re-arms the same instant). A `watch` ALWAYS carries a valid
 *  next occurrence: its `nextTick` (epoch ms) is the single evolving durable cursor, advanced past every
 *  missed occurrence as ticks are delivered — which is exactly what makes recovery fire one catch-up rather
 *  than backfilling. `invalid` hoists every "well-formed values, but the call cannot run" case out of the
 *  other variants (a malformed cron expression / timezone, a non-positive interval, a non-finite sleep
 *  deadline — all reachable runtime inputs): it is turned into a panic at dispatch. Structural drift (an
 *  unknown external key, a wrong-kind field — what the typechecker rules out) instead throws at the payload
 *  boundary as a defect. `deliverTo` may close over a secret, so a persisted `watch` operation seals like
 *  any stored value. */
export type TimeOperation =
  | { kind: "now" }
  | { kind: "sleep"; deadline: number }
  | { kind: "watch"; schedule: Schedule; deliverTo: Value; nextTick: number }
  | { kind: "invalid"; message: string };

/** A `time` call's whole transport payload: the operation plus the snapshot it pins. The snapshot is the
 *  calling agent's version — `watch` dispatches `deliverTo` against it, and every operation pins it uniformly
 *  (a non-null column, never a per-variant nullable) so a live time call keeps its version undeletable. */
export interface TimePayload {
  snapshot: SnapshotId;
  operation: TimeOperation;
}
