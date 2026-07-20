// Unit tests for the delegation-tree assembly — the pure heart of `GET /runs/:id/tree`. The queries
// around it need Postgres; this validates that the Layer 1 rows (delegations + instances + escalations)
// compose into the right tree: edge → callee instance → issued children, recursively.

import type { QualifiedName } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { toSnapshotId } from "../src/runtime/ids.js";
import {
  assembleDelegationTree,
  type TreeDelegationRow,
  type TreeEscalationRow,
  type TreeInstanceRow,
} from "../src/modules/run/run-tree.repository.js";

const at = (second: number) => new Date(2026, 0, 1, 0, 0, second);

function delegation(overrides: Partial<TreeDelegationRow> & { id: string }): TreeDelegationRow {
  return {
    callerInstanceId: null,
    toReactor: "core",
    state: "running",
    createdAt: at(0),
    ...overrides,
  };
}

function instance(overrides: Partial<TreeInstanceRow> & { id: string }): TreeInstanceRow {
  return {
    delegationId: null,
    kind: "core",
    status: "running",
    target: null,
    ffiKey: null,
    callStatus: null,
    snapshotId: null,
    ...overrides,
  };
}

const named = (name: string) => ({
  kind: "named" as const,
  name: name as QualifiedName,
  snapshot: toSnapshotId("snap-1"),
});

describe("assembleDelegationTree", () => {
  test("a run chain assembles root → callee → issued children, with labels per kind", () => {
    // The run's id is its permanent api-side run instance ("run-i"); the tree roots at the single
    // delegation that instance issued.
    const rows = {
      delegations: [
        delegation({ id: "d-root", callerInstanceId: "run-i" }),
        delegation({ id: "d-sub", callerInstanceId: "i-main", createdAt: at(1) }),
        delegation({ id: "d-ffi", callerInstanceId: "i-sub", toReactor: "ffi", createdAt: at(2) }),
      ],
      instances: [
        instance({ id: "run-i", kind: "api" }),
        instance({
          id: "i-main",
          delegationId: "d-root",
          target: named("main.main"),
          snapshotId: "snap-1",
        }),
        instance({ id: "i-sub", delegationId: "d-sub", target: named("main.helper") }),
        instance({
          id: "i-call",
          delegationId: "d-ffi",
          kind: "ffi",
          ffiKey: "main.greet",
          callStatus: "running",
        }),
      ],
      escalations: [],
    };

    const tree = assembleDelegationTree("run-i", rows);
    expect(tree).not.toBeNull();
    expect(tree?.delegationId).toBe("d-root");
    expect(tree?.instance?.target).toEqual({ kind: "agent", name: "main.main" });
    const sub = tree?.instance?.children[0];
    expect(sub?.instance?.target).toEqual({ kind: "agent", name: "main.helper" });
    const call = sub?.instance?.children[0];
    expect(call?.reactor).toBe("ffi");
    expect(call?.instance?.target).toEqual({ kind: "external", key: "main.greet" });
  });

  test("an issued-but-unaccepted delegate is a node without an instance", () => {
    const tree = assembleDelegationTree("run-i", {
      delegations: [delegation({ id: "d-root", callerInstanceId: "run-i" })],
      instances: [instance({ id: "run-i", kind: "api" })],
      escalations: [],
    });
    expect(tree?.instance).toBeNull();
    expect(tree?.state).toBe("running");
  });

  test("a terminal (or unknown) run has no tree", () => {
    expect(
      assembleDelegationTree("run-gone", { delegations: [], instances: [], escalations: [] }),
    ).toBeNull();
  });

  test("open escalations attach to their raiser; only the api-addressed leg is answerable", () => {
    const escalationRows: TreeEscalationRow[] = [
      {
        id: "e-root",
        raiserInstanceId: "i-main",
        request: "main.ask",
        toReactor: "api",
        createdAt: at(3),
      },
      {
        id: "e-relay",
        raiserInstanceId: "i-sub",
        request: "main.ask",
        toReactor: "core",
        createdAt: at(2),
      },
    ];
    const tree = assembleDelegationTree("run-i", {
      delegations: [
        delegation({ id: "d-root", callerInstanceId: "run-i" }),
        delegation({ id: "d-sub", callerInstanceId: "i-main" }),
      ],
      instances: [
        instance({ id: "run-i", kind: "api" }),
        instance({ id: "i-main", delegationId: "d-root", target: named("main.main") }),
        instance({ id: "i-sub", delegationId: "d-sub", target: named("main.helper") }),
      ],
      escalations: escalationRows,
    });
    expect(tree?.instance?.openEscalations).toEqual([
      { id: "e-root", request: "main.ask", answerable: true, createdAt: at(3) },
    ]);
    expect(tree?.instance?.children[0]?.instance?.openEscalations).toEqual([
      { id: "e-relay", request: "main.ask", answerable: false, createdAt: at(2) },
    ]);
  });

  test("a run-root FAILURE row addressed to the api is NOT answerable (only user-facing rows are)", () => {
    // Every escalate opens a durable row now — a panic / throw reaching the run root is a `to = api` row too
    // (the api fails the run on it), so `to === 'api'` alone no longer implies answerable: the user-facing
    // check on the `request` is what marks a failure un-answerable, exactly as the read filters do.
    const escalationRows: TreeEscalationRow[] = [
      {
        id: "e-panic",
        raiserInstanceId: "i-main",
        request: "prelude.panic",
        toReactor: "api",
        createdAt: at(4),
      },
      {
        id: "e-throw",
        raiserInstanceId: "i-main",
        request: "prelude.throw",
        toReactor: "api",
        createdAt: at(5),
      },
    ];
    const tree = assembleDelegationTree("run-i", {
      delegations: [delegation({ id: "d-root", callerInstanceId: "run-i" })],
      instances: [
        instance({ id: "run-i", kind: "api" }),
        instance({ id: "i-main", delegationId: "d-root", target: named("main.main") }),
      ],
      escalations: escalationRows,
    });
    expect(tree?.instance?.openEscalations).toEqual([
      { id: "e-panic", request: "prelude.panic", answerable: false, createdAt: at(4) },
      { id: "e-throw", request: "prelude.throw", answerable: false, createdAt: at(5) },
    ]);
  });

  test("parallel children come back oldest first, and an ffi call surfaces its own status", () => {
    const tree = assembleDelegationTree("run-i", {
      delegations: [
        delegation({ id: "d-root", callerInstanceId: "run-i" }),
        delegation({ id: "d-late", callerInstanceId: "i-main", createdAt: at(9) }),
        delegation({ id: "d-early", callerInstanceId: "i-main", toReactor: "ffi", createdAt: at(1) }),
      ],
      instances: [
        instance({ id: "run-i", kind: "api" }),
        instance({ id: "i-main", delegationId: "d-root", target: named("main.main") }),
        instance({
          id: "i-call",
          delegationId: "d-early",
          kind: "ffi",
          ffiKey: "main.slow",
          callStatus: "awaitingAnswer",
        }),
      ],
      escalations: [],
    });
    const children = tree?.instance?.children ?? [];
    expect(children.map((child) => child.delegationId)).toEqual(["d-early", "d-late"]);
    expect(children[0]?.instance?.status).toBe("awaitingAnswer");
  });

  test("a corrupt cycle truncates instead of hanging", () => {
    // The root's own delegation id reappears among its instance's issued children — impossible in a
    // healthy store, but the guard must degrade it to a truncated branch, never recurse forever. (The
    // run id here is "i-loop": the corrupt row makes the run's "instance" also the caller of the root.)
    const tree = assembleDelegationTree("i-loop", {
      delegations: [
        delegation({ id: "run-1", callerInstanceId: "i-loop" }),
        delegation({ id: "d-loop", callerInstanceId: "i-loop" }),
      ],
      instances: [
        instance({ id: "i-loop", delegationId: "run-1", target: named("main.loop") }),
        instance({ id: "i-loop-2", delegationId: "d-loop", target: named("main.loop") }),
      ],
      escalations: [],
    });
    expect(tree?.instance?.children.map((child) => child.delegationId)).toEqual(["d-loop"]);
  });
});
