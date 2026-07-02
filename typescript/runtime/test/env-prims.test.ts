// The env host primitives (`prelude.env.get_secret` / `prelude.env.get_all`) registered on the prim
// registry by `registerHostPrims`, exercised over a stubbed `EnvReader`. These assert the privacy contract
// at the source: a secret read is tainted `private`, a non-secret read is public, and a missing secret is a
// (deterministic) failure the engine turns into a `panic`.

import { describe, expect, test } from "vitest";
import type { PrimContext } from "../src/runtime/engine/context.js";
import { type EnvReader, registerHostPrims } from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import type { ProjectId } from "../src/runtime/ids.js";
import { SnapshotRegistry } from "../src/runtime/ir.js";
import { InMemoryBlobStore } from "../src/runtime/value/blob-store.js";
import type { Value } from "../src/runtime/value/types.js";

const PROJECT = "project-env" as ProjectId;

/** A minimal `PrimContext` for direct `prims.run` calls (env prims read neither IR nor blobs). */
const CONTEXT: PrimContext = {
  projectId: PROJECT,
  ir: new SnapshotRegistry(),
  blobs: new InMemoryBlobStore(),
};

/** A stub `EnvReader` over fixed secret / non-secret maps. */
function reader(secrets: Record<string, string>, publics: Record<string, string>): EnvReader {
  return {
    async readSecret(_projectId, key) {
      const value = secrets[key];
      return value === undefined ? null : value;
    },
    async readPublic(_projectId) {
      return publics;
    },
  };
}

function primsWith(env: EnvReader): PrimRegistry {
  const prims = new PrimRegistry();
  registerHostPrims(prims, { env });
  return prims;
}

function recordArgument(fields: Record<string, Value>): Value {
  return { kind: "record", fields };
}

describe("env host primitives", () => {
  test("get_secret returns the decrypted value tainted private", async () => {
    const prims = primsWith(reader({ API_KEY: "sk-123" }, {}));
    const result = await prims.run(
      "prelude.env.get_secret",
      recordArgument({ key: { kind: "string", value: "API_KEY" } }),
      CONTEXT,
    );
    expect(result).toEqual({ kind: "string", value: "sk-123", private: true });
  });

  test("get_secret on a missing secret throws (the engine raises a panic)", async () => {
    const prims = primsWith(reader({}, { API_KEY: "not-a-secret" }));
    await expect(
      prims.run(
        "prelude.env.get_secret",
        recordArgument({ key: { kind: "string", value: "API_KEY" } }),
        CONTEXT,
      ),
    ).rejects.toThrow(/API_KEY/);
  });

  test("get_all returns a public record of the non-secret entries", async () => {
    const prims = primsWith(reader({ SECRET: "sk-123" }, { HOST: "example.com", PORT: "443" }));
    const result = await prims.run("prelude.env.get_all", recordArgument({}), CONTEXT);
    expect(result).toEqual({
      kind: "record",
      fields: {
        HOST: { kind: "string", value: "example.com" },
        PORT: { kind: "string", value: "443" },
      },
    });
    // The result is public: no `private` marker anywhere (a non-secret entry must not be tainted).
    expect(result.private).toBeUndefined();
  });

  test("get_all keeps an env key literally named __proto__ as a real field (no silent drop)", async () => {
    // `Object.fromEntries` defines own properties, so `__proto__` is a real key here (an object literal
    // would set the prototype instead) — modelling a DB row whose key is `__proto__`.
    const publics = Object.fromEntries([
      ["__proto__", "danger"],
      ["HOST", "example.com"],
    ]);
    const prims = primsWith(reader({}, publics));
    const result = await prims.run("prelude.env.get_all", recordArgument({}), CONTEXT);
    expect(result.kind).toBe("record");
    if (result.kind === "record") {
      // The `__proto__` entry survives as an own field rather than corrupting the prototype / vanishing.
      expect(Object.hasOwn(result.fields, "__proto__")).toBe(true);
      expect(result.fields.__proto__).toEqual({ kind: "string", value: "danger" });
      expect(result.fields.HOST).toEqual({ kind: "string", value: "example.com" });
    }
  });
});
