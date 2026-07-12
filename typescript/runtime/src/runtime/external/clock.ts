// The `Clock` — the wall-clock + timer capability the `time` reactor reads through, injected exactly like the
// http / ffi / mcp transports so the reactor stays deterministic and testable. `now` is the instant a
// `time.now` records durably; `setTimer` / `clearTimer` are the one-shot timers `sleep` / `watch` wait on
// (one-shot rather than intervals, because the reactor re-arms each occurrence itself so the persisted
// deadline is always the single source of truth). Production wires `SystemClock`; tests wire `ManualClock`,
// which advances only when the test says so — no real waits, and downtime is simulated by starting the
// recovered clock at a later instant.

/** A live timer handle. Opaque to the reactor — only `Clock.clearTimer` interprets it. */
export interface TimerHandle {
  readonly id: number;
}

export interface Clock {
  /** The current wall-clock time as epoch milliseconds. */
  now(): number;
  /** Run `callback` once after at least `delayMs` (clamped to `>= 0`). Returns a handle to cancel it. */
  setTimer(delayMs: number, callback: () => void): TimerHandle;
  /** Cancel a timer that has not yet fired. Idempotent — a fired or already-cleared handle is a no-op. */
  clearTimer(handle: TimerHandle): void;
}

/** The production clock: `Date.now()` and `setTimeout`. */
export class SystemClock implements Clock {
  private sequence = 0;
  private readonly timers = new Map<number, ReturnType<typeof setTimeout>>();

  now(): number {
    return Date.now();
  }

  setTimer(delayMs: number, callback: () => void): TimerHandle {
    this.sequence += 1;
    const id = this.sequence;
    const timeout = setTimeout(
      () => {
        this.timers.delete(id);
        callback();
      },
      Math.max(0, delayMs),
    );
    // Never let a pending timer keep the process alive on its own — the runtime's lifecycle owns shutdown.
    if (typeof timeout === "object" && "unref" in timeout) timeout.unref();
    this.timers.set(id, timeout);
    return { id };
  }

  clearTimer(handle: TimerHandle): void {
    const timeout = this.timers.get(handle.id);
    if (timeout === undefined) return;
    clearTimeout(timeout);
    this.timers.delete(handle.id);
  }
}

/** The test clock: a manually advanced current instant plus a queue of pending timers. `advanceTo` /
 *  `advanceBy` move the clock and fire every timer whose deadline the move reached, in deadline order — so a
 *  test drives durable sleeps and schedule ticks deterministically with no real time. */
export class ManualClock implements Clock {
  private sequence = 0;
  private readonly pending = new Map<number, { fireAt: number; callback: () => void }>();

  constructor(private current: number) {}

  now(): number {
    return this.current;
  }

  setTimer(delayMs: number, callback: () => void): TimerHandle {
    this.sequence += 1;
    const id = this.sequence;
    this.pending.set(id, { fireAt: this.current + Math.max(0, delayMs), callback });
    return { id };
  }

  clearTimer(handle: TimerHandle): void {
    this.pending.delete(handle.id);
  }

  /** How many timers are armed but not yet fired — a test waits on this to know a durable timer is in place
   *  before advancing (the arming is asynchronous, several turns after `startRun`). */
  pendingCount(): number {
    return this.pending.size;
  }

  /** Move the clock to `epochMs` and fire every timer now due, earliest deadline first. A timer whose callback
   *  arms another timer due by `epochMs` fires within this same call (the loop re-scans), which is exactly a
   *  restart catch-up firing then re-arming — so a test never has to advance twice for one logical step. */
  advanceTo(epochMs: number): void {
    this.current = Math.max(this.current, epochMs);
    for (;;) {
      let due: { id: number; fireAt: number; callback: () => void } | undefined;
      for (const [id, timer] of this.pending) {
        if (timer.fireAt <= this.current && (due === undefined || timer.fireAt < due.fireAt)) {
          due = { id, fireAt: timer.fireAt, callback: timer.callback };
        }
      }
      if (due === undefined) return;
      this.pending.delete(due.id);
      due.callback();
    }
  }

  /** Advance the clock by `deltaMs` (see `advanceTo`). */
  advanceBy(deltaMs: number): void {
    this.advanceTo(this.current + deltaMs);
  }
}
