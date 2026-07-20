// The `Clock.setTimer` delay ceiling, enforced as a CONTRACT in every implementation. Node's `setTimeout`
// silently coerces a delay past 2^31-1 ms to 1 ms, so a caller that arms a raw long deadline misfires at
// once — and only in production, because a test clock has no such coercion. Enforcing the ceiling in
// `ManualClock` too is what closes that seam: the deterministic tests then reject the same over-long arm
// production would, so the chunking caller (`TimeReactor.arm`) cannot silently regress.

import { describe, expect, test } from "vitest";
import { ManualClock, MAX_TIMER_DELAY_MS, SystemClock } from "../src/runtime/external/clock.js";

describe("the Clock timer-delay ceiling", () => {
  test("SystemClock rejects a delay past the ceiling instead of letting Node coerce it to 1ms", () => {
    const clock = new SystemClock();
    expect(() => clock.setTimer(MAX_TIMER_DELAY_MS + 1, () => {})).toThrow(/timer ceiling/);
  });

  test("SystemClock accepts a delay exactly at the ceiling", () => {
    const clock = new SystemClock();
    const handle = clock.setTimer(MAX_TIMER_DELAY_MS, () => {});
    clock.clearTimer(handle);
  });

  test("ManualClock enforces the same contract, so deterministic tests walk the production rule", () => {
    const clock = new ManualClock(0);
    expect(() => clock.setTimer(MAX_TIMER_DELAY_MS + 1, () => {})).toThrow(/timer ceiling/);
    const handle = clock.setTimer(MAX_TIMER_DELAY_MS, () => {});
    clock.clearTimer(handle);
    expect(clock.pendingCount()).toBe(0);
  });
});
