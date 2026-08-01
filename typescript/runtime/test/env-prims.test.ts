// The env host primitives (`prelude.env.get_secret` / `prelude.env.get_or`) registered on the prim
// registry by `registerHostPrims`, exercised over a stubbed `EnvReader`. These assert the privacy contract
// at the source: a secret read is tainted `private`, a non-secret read is public, and a missing secret
// raises the typed `env.missing_secret` throw (an anticipated configuration failure, not a panic). The two
// readers also split on TOTALITY: `get_secret` throws on a missing key, `get_or` never does.

import { describe, expect, test } from "vitest";
import type { PrimContext } from "../src/runtime/engine/context.js";
import { type EnvReader, registerHostPrims } from "../src/runtime/engine/host-prims.js";
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

  test("get_or returns the non-secret entry as a public string", async () => {
    const prims = primsWith(reader({ SECRET: "sk-123" }, { HOST: "example.com", PORT: "443" }));
    const result = await prims.run("prelude.env.get_or", getOrArgument("HOST", "localhost"), CONTEXT);
    expect(result).toEqual({ kind: "string", value: "example.com" });
    // The result is public: no `private` marker (a non-secret entry must not be tainted).
    expect(result.private).toBeUndefined();
  });

  test("get_or falls back on an unset key, and a SECRET entry is not visible to it", async () => {
    // The secret bucket is off-limits here: `API_KEY` is set as a secret, so `get_or` still falls back —
    // the split that keeps a tainted value from leaking out as a public string.
    const prims = primsWith(reader({ API_KEY: "sk-123" }, { HOST: "example.com" }));
    const missing = await prims.run("prelude.env.get_or", getOrArgument("PORT", "443"), CONTEXT);
    expect(missing).toEqual({ kind: "string", value: "443" });
    const secret = await prims.run("prelude.env.get_or", getOrArgument("API_KEY", ""), CONTEXT);
    expect(secret).toEqual({ kind: "string", value: "" });
  });

  test("get_or returns an entry SET to the empty string as-is (set-but-empty is not unset)", async () => {
    const prims = primsWith(reader({}, { HOST: "" }));
    const result = await prims.run("prelude.env.get_or", getOrArgument("HOST", "fallback"), CONTEXT);
    expect(result).toEqual({ kind: "string", value: "" });
  });

  test("get_or reads an env key literally named __proto__ as its entry, not the prototype", async () => {
    // `Object.fromEntries` defines own properties, so `__proto__` is a real key here (an object literal
    // would set the prototype instead) — modelling a DB row whose key is `__proto__`. A plain `entries[key]`
    // read would answer with `Object.prototype`, so the own-property check is what keeps this a string.
    const publics = Object.fromEntries([
      ["__proto__", "danger"],
      ["HOST", "example.com"],
    ]);
    const prims = primsWith(reader({}, publics));
    const result = await prims.run(
      "prelude.env.get_or",
      getOrArgument("__proto__", "fallback"),
      CONTEXT,
    );
    expect(result).toEqual({ kind: "string", value: "danger" });
    // A key that is only an Object.prototype member (never a row) still falls back.
    const inherited = await prims.run(
      "prelude.env.get_or",
      getOrArgument("constructor", "fallback"),
      CONTEXT,
    );
    expect(inherited).toEqual({ kind: "string", value: "fallback" });
  });
});

function getOrArgument(key: string, fallback: string): Value {
  return recordArgument({
    key: { kind: "string", value: key },
    fallback: { kind: "string", value: fallback },
  });
}
