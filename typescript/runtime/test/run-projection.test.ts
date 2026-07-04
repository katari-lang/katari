// Unit test for the run projection — the pure mapping from a `runs` row to the API run view. The run's
// durable state / outcome lives on the `runs` row (the run delegation is deleted on terminal), so the
// projection just reads those columns (the Drizzle query around it needs Postgres; the mapping is pure).

import { describe, expect, test } from "vitest";
import { projectRun, type RunRow } from "../src/modules/run/run.repository.js";

const base: RunRow = {
  id: "run-1",
  name: "nightly",
  qualifiedName: "demo.main",
  snapshotId: "snap-1",
  state: "running",
  argument: { kind: "integer", value: 3 },
  result: null,
  errorMessage: null,
  cancelReason: null,
  createdAt: new Date("2026-06-25T00:00:00Z"),
  completedAt: null,
};

describe("run projection", () => {
  test("a freshly-launched run is `running` with no outcome", () => {
    const view = projectRun(base);
    expect(view.state).toBe("running");
    expect(view.result).toBeNull();
    expect(view.errorMessage).toBeNull();
    expect(view.completedAt).toBeNull();
    // Metadata flows straight through.
    expect(view.name).toBe("nightly");
    expect(view.qualifiedName).toBe("demo.main");
    expect(view.argument).toEqual({ kind: "integer", value: 3 });
  });

  test("a done run projects its result + completion time", () => {
    const completedAt = new Date("2026-06-25T00:05:00Z");
    const view = projectRun({
      ...base,
      state: "done",
      result: { kind: "string", value: "ok" },
      completedAt,
    });
    expect(view.state).toBe("done");
    expect(view.result).toEqual({ kind: "string", value: "ok" });
    expect(view.errorMessage).toBeNull();
    expect(view.completedAt).toBe(completedAt);
  });

  test("an errored run projects `error` + the message (not a result)", () => {
    const view = projectRun({
      ...base,
      state: "error",
      errorMessage: "panic: boom",
      result: { kind: "string", value: "stale" },
      completedAt: new Date("2026-06-25T00:06:00Z"),
    });
    expect(view.state).toBe("error");
    expect(view.errorMessage).toBe("panic: boom");
    expect(view.result).toBeNull(); // result is meaningful only for `done`
    expect(view.completedAt).not.toBeNull();
  });

  test("a cancelled run projects `cancelled` with the user's reason", () => {
    const view = projectRun({
      ...base,
      state: "cancelled",
      cancelReason: "user requested",
      completedAt: new Date("2026-06-25T00:07:00Z"),
    });
    expect(view.state).toBe("cancelled");
    expect(view.cancelReason).toBe("user requested");
    expect(view.completedAt).not.toBeNull();
  });

  test("a cancelling run is still in flight (no completion time)", () => {
    const view = projectRun({ ...base, state: "cancelling" });
    expect(view.state).toBe("cancelling");
    expect(view.completedAt).toBeNull();
  });
});
