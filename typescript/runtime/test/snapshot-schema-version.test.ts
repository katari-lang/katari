// The snapshot deploy's IR schema-version gate: an inlined module built for a version the runtime does
// not speak is rejected (400) before any DB work, while a module at the current version — or one
// referenced by hash alone (already gated at its first upload) — passes. Exercised against the pure
// `assertDeploySchemaVersions` so both paths run without a database.

import { type IRModule, SUPPORTED_IR_SCHEMA_VERSION } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { BadRequestError } from "../src/lib/errors.js";
import type { DeploySnapshotInput } from "../src/modules/snapshot/snapshot.schema.js";
import { assertDeploySchemaVersions } from "../src/modules/snapshot/snapshot.service.js";

/** A minimal but well-formed module IR stamped with `version` — the smallest thing the gate inspects. */
function moduleAt(version: number): IRModule {
  return { metadata: { schemaVersion: version }, blocks: {}, entries: {}, names: {} };
}

/** A deploy body inlining one module IR under `main`. */
function deployInlining(ir: IRModule): DeploySnapshotInput {
  return { message: "deploy", modules: { main: { hash: "hash-main", ir } } };
}

describe("assertDeploySchemaVersions", () => {
  test("accepts a module inlined at the runtime's current schema version", () => {
    expect(() =>
      assertDeploySchemaVersions(deployInlining(moduleAt(SUPPORTED_IR_SCHEMA_VERSION))),
    ).not.toThrow();
  });

  test("accepts a module referenced by hash alone (already gated at its first upload)", () => {
    const input: DeploySnapshotInput = { message: "deploy", modules: { main: { hash: "held" } } };
    expect(() => assertDeploySchemaVersions(input)).not.toThrow();
  });

  test("rejects an older schema version, naming both versions", () => {
    const stale = SUPPORTED_IR_SCHEMA_VERSION - 1;
    let thrown: unknown;
    try {
      assertDeploySchemaVersions(deployInlining(moduleAt(stale)));
    } catch (error) {
      thrown = error;
    }
    expect(thrown).toBeInstanceOf(BadRequestError);
    expect(thrown).toHaveProperty("status", 400);
    const message = thrown instanceof Error ? thrown.message : "";
    // Both the IR's version and the runtime's supported version must appear, so an operator can see the skew.
    expect(message).toContain(String(stale));
    expect(message).toContain(String(SUPPORTED_IR_SCHEMA_VERSION));
    expect(message).toContain("main");
  });
});
