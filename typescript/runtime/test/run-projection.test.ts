// Unit test for the run projection — the pure mapping from a run's metadata + its Layer 1 delegation row to
// the API run view. This is the testable heart of the "read run outcome from Layer 1" path (the Drizzle
// join around it needs Postgres; the mapping is pure).

import { describe, expect, test } from "vitest";
import {
  delegationToRunState,
  projectRun,
  type RunProjectionRow,
} from "../src/modules/run/run.repository.js";

const base: RunProjectionRow = {
  id: "run-1",
  name: "nightly",
  qualifiedName: "demo.main",
  snapshotId: "snap-1",
  argument: { kind: "integer", value: 3 },
  cancelReason: null,
  createdAt: new Date("2026-06-25T00:00:00Z"),
  delegationState: null,
  delegationResult: null,
  delegationError: null,
  delegationUpdatedAt: null,
};

describe("run projection", () => {
  test("maps each delegation state to its API run state", () => {
    expect(delegationToRunState("running")).toBe("running");
    expect(delegationToRunState("cancelling")).toBe("cancelling");
    expect(delegationToRunState("done")).toBe("done");
    expect(delegationToRunState("gone")).toBe("cancelled");
    expect(delegationToRunState("failed")).toBe("error");
  });

  test("a run with no delegation row yet is still `running` (the brief post-launch window)", () => {
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

  test("a done delegation projects its result + completion time", () => {
    const completedAt = new Date("2026-06-25T00:05:00Z");
    const view = projectRun({
      ...base,
      delegationState: "done",
      delegationResult: { kind: "string", value: "ok" },
      delegationUpdatedAt: completedAt,
    });
    expect(view.state).toBe("done");
    expect(view.result).toEqual({ kind: "string", value: "ok" });
    expect(view.errorMessage).toBeNull();
    expect(view.completedAt).toBe(completedAt);
  });

  test("a failed delegation projects `error` + the message (not a result)", () => {
    const view = projectRun({
      ...base,
      delegationState: "failed",
      delegationError: "panic: boom",
      delegationResult: { kind: "string", value: "stale" },
      delegationUpdatedAt: new Date("2026-06-25T00:06:00Z"),
    });
    expect(view.state).toBe("error");
    expect(view.errorMessage).toBe("panic: boom");
    expect(view.result).toBeNull(); // result is meaningful only for `done`
    expect(view.completedAt).not.toBeNull();
  });

  test("a gone delegation projects `cancelled` with the user's reason from the metadata sidecar", () => {
    const view = projectRun({
      ...base,
      cancelReason: "user requested",
      delegationState: "gone",
      delegationUpdatedAt: new Date("2026-06-25T00:07:00Z"),
    });
    expect(view.state).toBe("cancelled");
    expect(view.cancelReason).toBe("user requested");
    expect(view.completedAt).not.toBeNull();
  });

  test("a cancelling delegation is still in flight (no completion time)", () => {
    const view = projectRun({ ...base, delegationState: "cancelling" });
    expect(view.state).toBe("cancelling");
    expect(view.completedAt).toBeNull();
  });
});
