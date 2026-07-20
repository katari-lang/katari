// TimeReactor: the `time` reactor — durable wall-clock time as a call reactor (see `ExternalCallReactor` for
// the shared callee-call lifecycle). Each compiled `prelude.time.*` external reaches it as a `delegate` (an
// external leaf marked `reactor: "time"`) and becomes a `TimeOperation` decided ONCE at `openPayload`, keyed
// by the delegate's fully-qualified external key — after which every lifecycle method dispatches that sum:
//   - `now` (`prelude.time.now`): resolve with the current instant. It routes through the reactor rather
//     than a prim so the nondeterministic clock read happens OUTSIDE any engine turn: the instant rides a
//     `delegateAck` the caller's turn merely consumes, and the commit landing that consumption makes value
//     and observer durable together — a prim's `Date.now()` would instead re-run inside a replayed turn
//     and disagree with itself. A restart BEFORE that commit re-resolves the open call from the current
//     clock (see `recover`), which is sound: nothing durable observed the earlier instant. `now` opens no
//     timer; it resolves on the next turn.
//   - `sleep` / `sleep_until` (`prelude.time.sleep` / `.sleep_until`): resolve with `null` at an ABSOLUTE
//     deadline. A relative `sleep(ms)` collapses to `now + ms` at open (both operations become one `sleep`
//     variant), so recovery re-arms the exact same instant — and a deadline that passed while the runtime was
//     down arms delay 0 and fires at once.
//   - `watch` (`prelude.time.watch`): fire `deliver_to` once per schedule occurrence, forever, via an inner
//     delegation carrying the occurrence's scheduled epoch ms — the discord-watch shape. Deliveries are
//     SERIALIZED (the next occurrence arms only when the current delivery settles), so the persisted
//     `nextTick` cursor is the single source of truth: a restart re-arms it, firing one catch-up if it
//     already passed (never backfilling every missed occurrence) and then continuing on schedule. A
//     `deliver_to` failure (throw / panic) settles the WHOLE call as that failure — the watch dies, with no
//     built-in retry (resilience is composed at the call site).
//
// Timers are the injected `Clock`'s one-shot timers (kept in `timers`, one per live call); a fired timer
// re-enters the serial loop through `schedule` (like webhook's post-commit work), so its `complete` /
// inner-delegation commits with a turn. The recovery story matches webhook: there is no external process to
// reconcile, so a time call survives a restart completely — its operation reloads from its extension
// document and its timer re-arms; only an in-flight tick delivery's core work resumes on its own.

import type { Json } from "@katari-lang/types";
import { CronExpressionParser } from "cron-parser";
import { dispatchCallable } from "../engine/dynamic-dispatch.js";
import type { ReactorName } from "../event/types.js";
import { type Clock, MAX_TIMER_DELAY_MS, type TimerHandle } from "../external/clock.js";
import type { DelegationId, SnapshotId } from "../ids.js";
import type { Schedule, TimeOperation, TimePayload } from "../time-schedule.js";
import type { GenericSubstitution, Value } from "../value/types.js";
import {
  asJson,
  documentOf,
  encodeInnerCalls,
  encodeRelays,
  innerCallsOf,
  relaysOf,
  stringFieldOf,
  warmFieldOf,
} from "./extension-codec.js";
import {
  type CallRow,
  type DecodedCallExtension,
  type EscalationRelayRow,
  ExternalCallReactor,
  type ExternalTarget,
  type InnerCallRow,
  type InnerDelivery,
  innerOutcomeAsCompletion,
} from "./external-call-reactor.js";
import { messageOf } from "./failure.js";
import type { ResourcePool } from "./resource-pool.js";

/** The time extension document: everything a reload re-arms — the whole per-variant `operation` (the
 *  durable `sleep` deadline, a `watch`'s schedule + next-occurrence cursor + `deliver_to`, which may
 *  close over a secret — the sealed subtree sits inside this document), the version pin a `watch`'s
 *  deliveries dispatch against, and the inner-delegation bridges (only a `watch`'s per-tick delivery
 *  opens inner delegations; `now` / `sleep` keep them empty). */
export interface TimeExtension {
  snapshotId: SnapshotId;
  operation: TimeOperation;
  relays: EscalationRelayRow[];
  innerCalls: InnerCallRow[];
}

/** Encode a time call's extension document (pure — the persistence port seals it as a whole). */
export function encodeTimeExtension(extension: TimeExtension): Json {
  return {
    snapshotId: extension.snapshotId,
    operation: asJson(extension.operation),
    relays: encodeRelays(extension.relays),
    innerCalls: encodeInnerCalls(extension.innerCalls),
  };
}

/** Decode a time call's extension document (pure). */
export function decodeTimeExtension(extension: Json): TimeExtension {
  const document = documentOf(extension);
  return {
    snapshotId: stringFieldOf(document, "snapshotId") as SnapshotId,
    operation: warmFieldOf<TimeOperation>(document, "operation"),
    relays: relaysOf(document),
    innerCalls: innerCallsOf(document),
  };
}

/** The compiled external keys (fully-qualified names) the `prelude.time.*` calls arrive under — compared
 *  exactly here, at the payload boundary, then never again (past `openPayload` the call is a `TimeOperation`
 *  variant, not a key sniff). */
const NOW_KEY = "prelude.time.now";
const SLEEP_KEY = "prelude.time.sleep";
const SLEEP_UNTIL_KEY = "prelude.time.sleep_until";
const WATCH_KEY = "prelude.time.watch";

/** The data constructors of the `schedule` sum a `watch` argument carries. */
const INTERVAL_CTOR = "prelude.time.interval";
const CRON_CTOR = "prelude.time.cron";

/** The single in-flight tick delivery's inner-call token. A watch serializes ticks (one at a time), so one
 *  reserved token suffices. */
const TICK_CALL = "tick";

export class TimeReactor extends ExternalCallReactor<TimePayload> {
  readonly name: ReactorName = "time";

  /** The live timer per call (a `sleep` deadline, or a `watch`'s armed next occurrence). One at a time per
   *  call — arming clears the previous — so the map holds at most one handle per delegation. */
  private readonly timers = new Map<DelegationId, TimerHandle>();

  constructor(
    /** The wall-clock + one-shot timers this reactor reads through (`SystemClock` in production, a controllable
     *  clock in tests) — the sole source of "what time is it" and "wake me at". */
    private readonly clock: Clock,
    /** Schedule a fresh reactor turn (the substrate's serial mailbox) — how a fired timer re-enters the
     *  transactional loop, like webhook's post-commit work. */
    private readonly schedule: (work: () => void) => void,
    pool: ResourcePool,
  ) {
    super(pool);
  }

  // ─── the ExternalCallReactor hooks ───────────────────────────────────────────────────────────────

  protected openPayload(
    target: ExternalTarget,
    argument: Value | null,
    _generics: GenericSubstitution | undefined,
  ): TimePayload {
    const fields = argument !== null && argument.kind === "record" ? argument.fields : {};
    return { snapshot: target.snapshot, operation: this.openOperation(target.key, fields) };
  }

  /** Decide the operation once, from the external key and argument. `sleep` / `sleep_until` collapse to one
   *  absolute deadline; a `watch` computes (and validates) its first occurrence here, hoisting an unusable
   *  schedule to `invalid` rather than a nullable field. An unknown key throws: the typechecker restricts
   *  `from "time"` to the compiled stdlib externals (a user module's claim on the reactor is K3022), so a
   *  key outside the four above is engine/compiler drift — a defect, not an input to degrade around. */
  private openOperation(key: string, fields: Record<string, Value>): TimeOperation {
    switch (key) {
      case NOW_KEY:
        return { kind: "now" };
      case SLEEP_KEY:
        return sleepOperation(this.clock.now() + numberOf(fields.milliseconds));
      case SLEEP_UNTIL_KEY:
        return sleepOperation(numberOf(fields.time));
      case WATCH_KEY:
        return this.openWatch(fields);
      default:
        throw new Error(`time: unknown external key "${key}" (compiler/runtime drift — a bug)`);
    }
  }

  /** Parse a `watch`'s schedule and deliver_to, and compute its first occurrence. A schedule that cannot
   *  YIELD an occurrence (a bad cron expression / timezone, a non-positive interval — reachable runtime
   *  inputs) becomes `invalid`, a panic at dispatch; a structurally absent `deliver_to` throws instead
   *  (the typechecker requires it, so its absence is drift, like an unknown key). */
  private openWatch(fields: Record<string, Value>): TimeOperation {
    const schedule = parseSchedule(fields.schedule);
    const deliverTo = fields.deliver_to;
    if (deliverTo === undefined) {
      throw new Error("time.watch: no deliver_to argument (compiler/runtime drift — a bug)");
    }
    const start = this.clock.now();
    try {
      // The first occurrence uses `start` as both the phase anchor (interval) and the not-before bound.
      return {
        kind: "watch",
        schedule,
        deliverTo,
        nextTick: nextOccurrence(schedule, start, start),
      };
    } catch (error) {
      return { kind: "invalid", message: messageOf(error) };
    }
  }

  /** Post-commit: begin the operation. `now` resolves on the next turn; `sleep` / `watch` arm a timer; an
   *  `invalid` operation fails the run as a panic. */
  protected dispatch(delegation: DelegationId, payload: TimePayload): void {
    const operation = payload.operation;
    switch (operation.kind) {
      case "now":
        this.schedule(() => this.completeNow(delegation));
        return;
      case "sleep":
        this.arm(delegation, operation.deadline);
        return;
      case "watch":
        this.arm(delegation, operation.nextTick);
        return;
      case "invalid":
        this.schedule(() =>
          this.complete({ delegation, outcome: errorOutcome(operation.message) }),
        );
        return;
    }
  }

  /** Reactivation: re-arm the reloaded call's timer. Nothing external to reconcile — a time call survives a
   *  restart completely (like webhook). A `now` re-resolves (no result was committed, else the call is gone);
   *  a `sleep` / `watch` re-arms from its persisted deadline (a passed one fires immediately — the single
   *  catch-up). A `watch` whose tick delivery is still in flight (durable core work resuming) is NOT re-armed
   *  here — that delivery's completion arms the next occurrence. */
  protected recover(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    const operation = payload.operation;
    switch (operation.kind) {
      case "now":
        this.schedule(() => this.completeNow(delegation));
        return;
      case "sleep":
        this.arm(delegation, operation.deadline);
        return;
      case "watch": {
        const instance = this.callInstance(delegation);
        if (instance !== undefined && this.hasIssuedDelegations(instance)) return;
        this.arm(delegation, operation.nextTick);
        return;
      }
      case "invalid":
        this.schedule(() =>
          this.complete({ delegation, outcome: errorOutcome(operation.message) }),
        );
        return;
    }
  }

  /** A cancel's transport half: disarm the timer and confirm on a fresh turn (a watch's in-flight tick drains
   *  through the base's cancel cascade). */
  protected abort(delegation: DelegationId): void {
    this.clearTimerFor(delegation);
    this.schedule(() => this.complete({ delegation, outcome: { kind: "cancelled" } }));
  }

  /** A settled tick delivery. A success re-arms the next occurrence (the cursor already advanced when the tick
   *  fired); a cancelled tick is part of teardown, so nothing to do. A tick's EXECUTION failure no longer
   *  settles the delivery — it proxies UP like any escalation and cancels the whole watch — so the only
   *  outcomes that reach here are `result` and `cancelled` (the `error` arm is a defensive residue). */
  protected override deliverInnerOutcome(delivery: InnerDelivery): void {
    switch (delivery.outcome.kind) {
      case "result":
        this.armWatch(delivery.delegation);
        return;
      case "error":
        this.schedule(() =>
          this.complete({
            delegation: delivery.delegation,
            outcome: innerOutcomeAsCompletion(delivery.outcome),
          }),
        );
        return;
      case "cancelled":
        return;
    }
  }

  /** The call resolved — disarm any timer (covers every resolution path at once). */
  protected override onDropCall(delegation: DelegationId): void {
    this.clearTimerFor(delegation);
  }

  protected encodeCallExtension(row: CallRow<TimePayload>): Json {
    return encodeTimeExtension({
      snapshotId: row.payload.snapshot,
      operation: row.payload.operation,
      relays: row.relays,
      innerCalls: row.innerCalls,
    });
  }

  protected decodeCallExtension(extension: Json): DecodedCallExtension<TimePayload> {
    const decoded = decodeTimeExtension(extension);
    return {
      payload: { snapshot: decoded.snapshotId, operation: decoded.operation },
      relays: decoded.relays,
      innerCalls: decoded.innerCalls,
    };
  }

  override reset(): void {
    super.reset();
    for (const handle of this.timers.values()) this.clock.clearTimer(handle);
    this.timers.clear();
  }

  // ─── timers ──────────────────────────────────────────────────────────────────────────────────────

  /** A fired timer (in a fresh turn): resolve a `sleep` with `null` or fire a `watch` tick. Only those two
   *  variants ever arm a timer (`now` and `invalid` resolve on a scheduled turn at dispatch), so a timer
   *  firing for either is a reactor bug — thrown, not served. A call gone before its timer fired is a
   *  no-op (the timer was disarmed with the call; this covers a race with a same-turn resolution). */
  private onTimer(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined) return;
    const operation = payload.operation;
    switch (operation.kind) {
      case "sleep":
        this.complete({ delegation, outcome: { kind: "result", value: null } });
        return;
      case "watch":
        this.fireWatchTick(delegation, operation);
        return;
      case "now":
      case "invalid":
        throw new Error(
          `time: a timer fired for a "${operation.kind}" operation, which never arms one (a bug)`,
        );
    }
  }

  /** Fire one watch occurrence (in a turn): advance the cursor to the next occurrence (persisted with this
   *  turn via `openInnerDelegation`'s dirty mark), then deliver the just-fired occurrence's scheduled epoch ms
   *  to `deliver_to`. The next timer is NOT armed here — it arms when this delivery settles (serialized). */
  private fireWatchTick(
    delegation: DelegationId,
    operation: Extract<TimeOperation, { kind: "watch" }>,
  ): void {
    const scheduledTick = operation.nextTick;
    let next: number;
    try {
      next = nextOccurrence(operation.schedule, scheduledTick, this.clock.now());
    } catch (error) {
      // A schedule that validated at open but fails to advance now is a defect — fail the watch as a panic.
      this.complete({ delegation, outcome: errorOutcome(messageOf(error)) });
      return;
    }
    operation.nextTick = next;
    const argument: Value = {
      kind: "record",
      fields: { time: { kind: "number", value: scheduledTick } },
    };
    const dispatched = dispatchCallable(operation.deliverTo, argument);
    if ("error" in dispatched) {
      this.complete({
        delegation,
        outcome: errorOutcome(`time.watch: deliver_to is ${dispatched.error}`),
      });
      return;
    }
    // A null open means the call is winding down (cancelling / already settling) — the teardown path settles
    // it, so there is nothing to do here.
    this.openInnerDelegation(
      delegation,
      dispatched.target,
      dispatched.to,
      dispatched.argument,
      TICK_CALL,
      dispatched.generics,
    );
  }

  /** Resolve a `now` call with the current instant. The value rides the `delegateAck` and becomes durable
   *  with the commit that lands the caller's consumption of it (see the header's `now` paragraph). */
  private completeNow(delegation: DelegationId): void {
    this.complete({ delegation, outcome: { kind: "result", value: this.clock.now() } });
  }

  /** Re-arm a watch's next occurrence after a delivery settled (post-commit side effect — the cursor already
   *  advanced when the tick fired, so this only schedules the timer). */
  private armWatch(delegation: DelegationId): void {
    const payload = this.payloadOf(delegation);
    if (payload === undefined || payload.operation.kind !== "watch") return;
    this.arm(delegation, payload.operation.nextTick);
  }

  /** Arm the single timer for `delegation` to fire at `deadlineEpochMs` (a passed deadline arms delay 0 → the
   *  next tick fires at once). Replaces any existing timer for the call. A deadline farther out than one
   *  timer may carry (`MAX_TIMER_DELAY_MS`, ~24.8 days — Node coerces a longer `setTimeout` delay to 1 ms)
   *  is reached by chunked hops: a wake short of the deadline just re-arms the remainder, and only a wake AT
   *  (or past) the deadline fires the operation. A hop is a pure in-memory re-arm off the already-persisted
   *  deadline, so it needs no turn; chunking lives here — the one place deadlines become timers — rather
   *  than inside `SystemClock`, so the `ManualClock` tests walk the same path production does. */
  private arm(delegation: DelegationId, deadlineEpochMs: number): void {
    this.clearTimerFor(delegation);
    const delay = Math.min(Math.max(0, deadlineEpochMs - this.clock.now()), MAX_TIMER_DELAY_MS);
    const handle = this.clock.setTimer(delay, () => {
      this.timers.delete(delegation);
      if (this.clock.now() < deadlineEpochMs) {
        this.arm(delegation, deadlineEpochMs);
        return;
      }
      this.schedule(() => this.onTimer(delegation));
    });
    this.timers.set(delegation, handle);
  }

  private clearTimerFor(delegation: DelegationId): void {
    const handle = this.timers.get(delegation);
    if (handle === undefined) return;
    this.clock.clearTimer(handle);
    this.timers.delete(delegation);
  }
}

/** Read a number/integer value field as a JS number. A missing / wrong-kind field throws: the stdlib
 *  signatures type these fields, so a malformed one is compiler/runtime drift — surfaced as a defect, not
 *  degraded to a NaN that would hang a manual clock and misfire a system one. */
function numberOf(value: Value | undefined): number {
  if (value !== undefined && (value.kind === "number" || value.kind === "integer"))
    return value.value;
  throw new Error(
    `time: expected a number argument, got ${value === undefined ? "nothing" : value.kind} (compiler/runtime drift — a bug)`,
  );
}

/** Read a `schedule` sum value into the runtime `Schedule`, dispatching on its data constructor. A value
 *  that is neither `interval` nor `cron` throws — the `schedule` synonym admits exactly those two
 *  constructors, so anything else is compiler/runtime drift, like an unknown external key. */
function parseSchedule(value: Value | undefined): Schedule {
  if (value !== undefined && value.kind === "record") {
    if (value.ctor === INTERVAL_CTOR) {
      return { kind: "interval", milliseconds: numberOf(value.fields.milliseconds) };
    }
    if (value.ctor === CRON_CTOR) {
      return {
        kind: "cron",
        expression: stringOf(value.fields.expression),
        timezone: stringOf(value.fields.timezone),
      };
    }
  }
  throw new Error(
    "time.watch: the schedule is neither an interval nor a cron value (compiler/runtime drift — a bug)",
  );
}

/** Read a string field, throwing on a missing / wrong-kind one for the same drift-is-a-defect reason as
 *  `numberOf` (a silently-empty cron expression would fail later with a misleading parse error). */
function stringOf(value: Value | undefined): string {
  if (value !== undefined && value.kind === "string") return value.value;
  throw new Error(
    `time: expected a string argument, got ${value === undefined ? "nothing" : value.kind} (compiler/runtime drift — a bug)`,
  );
}

/** A `sleep`'s absolute deadline, validated ONCE at open: a non-finite deadline (a NaN / infinite argument —
 *  a correct program never sleeps toward one) becomes `invalid`, a panic at dispatch, because no timer can
 *  honestly be armed for it — `NaN <= x` is false, so a manual clock would hang while a system `setTimeout`
 *  would fire at once, silently divergent. */
function sleepOperation(deadlineEpochMs: number): TimeOperation {
  if (!Number.isFinite(deadlineEpochMs)) {
    return {
      kind: "invalid",
      message: `time.sleep: the deadline must be a finite epoch-ms number (got ${deadlineEpochMs})`,
    };
  }
  return { kind: "sleep", deadline: deadlineEpochMs };
}

/** The next occurrence strictly after `notBefore` (epoch ms), skipping every missed one — so a slow delivery
 *  or a restart fires a single catch-up, never a backfill. `interval` counts from `previousTick` (preserving
 *  the start phase) up past `notBefore`; `cron` reads the expression's next occurrence after `notBefore` in
 *  its timezone (cron carries its own phase). Throws for a schedule that cannot yield an occurrence (a
 *  non-positive interval, a malformed cron expression / timezone) — the caller turns that into `invalid`. */
function nextOccurrence(schedule: Schedule, previousTick: number, notBefore: number): number {
  switch (schedule.kind) {
    case "interval": {
      if (!(Number.isFinite(schedule.milliseconds) && schedule.milliseconds > 0)) {
        throw new Error(
          `time.watch: interval milliseconds must be a positive number (got ${schedule.milliseconds})`,
        );
      }
      let tick = previousTick + schedule.milliseconds;
      while (tick <= notBefore) tick += schedule.milliseconds;
      return tick;
    }
    case "cron": {
      // cron-parser's `next()` is exclusive of `currentDate`, so an occurrence exactly at `notBefore` yields
      // the FOLLOWING one — no same-instant re-fire.
      const iterator = CronExpressionParser.parse(schedule.expression, {
        currentDate: new Date(notBefore),
        tz: schedule.timezone,
      });
      return iterator.next().getTime();
    }
  }
}

/** A no-result error outcome — the reactor escalates it as a panic (the default `escalateError`), so a
 *  malformed schedule / broken invariant fails the run rather than sitting as an open question. */
function errorOutcome(message: string): { kind: "error"; message: string } {
  return { kind: "error", message };
}
