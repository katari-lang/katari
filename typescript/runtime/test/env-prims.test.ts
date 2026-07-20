// The env host primitives (`prelude.env.get_secret` / `prelude.env.get_all`) registered on the prim
// registry by `registerHostPrims`, exercised over a stubbed `EnvReader`. These assert the privacy contract
// at the source: a secret read is tainted `private`, a non-secret read is public, and a missing secret
// raises the typed `env.missing_secret` throw (an anticipated configuration failure, not a panic).

import { describe, expect, test } from "vitest";
import type { PrimContext } from "../src/runtime/engine/context.js";
import { type EnvReader, registerHostPrims, type StoreRows } from "../src/runtime/engine/host-prims.js";
import { PrimRegistry } from "../src/runtime/engine/prims.js";
import { KatariThrow } from "../src/runtime/engine/throw-signal.js";
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
  blobEntryOf: () => undefined,
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

const STUB_STORE_ROWS: StoreRows = {
  read: async () => undefined,
  upsert: async () => {},
  remove: async () => {},
  listKeys: async () => [],
  isBlobReferenced: async () => false,
};

function primsWith(env: EnvReader): PrimRegistry {
  const prims = new PrimRegistry();
  registerHostPrims(prims, { env, store: STUB_STORE_ROWS });
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

  test("get_secret on a missing secret raises the typed `env.missing_secret` throw", async () => {
    // A non-secret entry under the same key does not count: `get_secret` reads the secret bucket only.
    const prims = primsWith(reader({}, { API_KEY: "not-a-secret" }));
    const failure = await prims
      .run(
        "prelude.env.get_secret",
        recordArgument({ key: { kind: "string", value: "API_KEY" } }),
        CONTEXT,
      )
      .then(
        () => {
          throw new Error("expected get_secret to throw");
        },
        (error: unknown) => error,
      );
    expect(failure).toBeInstanceOf(KatariThrow);
    if (failure instanceof KatariThrow) {
      expect(failure.payload).toEqual({
        kind: "record",
        ctor: "prelude.env.missing_secret",
        fields: {
          key: { kind: "string", value: "API_KEY" },
          message: { kind: "string", value: 'env.get_secret: no secret is set under "API_KEY"' },
        },
      });
    }
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
