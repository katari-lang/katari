// Trip-wire: the stdlib's `primitive agent` declarations (the compiler half) must have exactly one
// runtime implementation each, and vice versa. A `primitive` in the stdlib with no registered
// implementation surfaces only as a runtime `throw new Error("unknown primitive: ...")` deep inside a
// run (`prims.ts` `PrimRegistry.run`), so this static name-set check is the ONLY pre-execution detection
// of the drift. It compares two source-derived sets:
//
//   (a) the qualified prim names the compiler emits — one per `primitive agent NAME` in
//       `haskell/compiler/stdlib/prelude.ktr` (→ `prelude.NAME`) and each `prelude/SUB.ktr`
//       (→ `prelude.SUB.NAME`), the module prefix coming from the file path;
//   (b) the names the runtime registers — the object keys of `BUILTIN_PRIMITIVES` (`prims.ts`) and
//       `INTEROP_PRIMITIVES` (`interop-prims.ts`), plus the host-registered names in `host-prims.ts`
//       (`prims.register("prelude.env.*", ...)`, wired at boot, bound to the project's env store).
//
// Both sides are read from source text rather than imported: `BUILTIN_PRIMITIVES` is not exported, and
// the host prims are registered imperatively at boot, so there is no single runtime value to enumerate.
// The parse is anchored (a leading `"prelude.…":` object key, a `prims.register("prelude.…"` call) so
// the `prelude.*` strings that name domain-error constructors / metadata ctors are not mistaken for
// registrations.

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { withoutCommentsAndDocstrings } from "./katari-source.js";

const repoRoot = new URL("../../../", import.meta.url);
const stdlibDir = new URL("haskell/compiler/stdlib/", repoRoot);
const engineDir = new URL("typescript/runtime/src/runtime/engine/", repoRoot);

/** The module prefix a stdlib `.ktr` file lowers under: `prelude.ktr` → `prelude`, `prelude/math.ktr`
 *  → `prelude.math` (the compiler's own path-to-module-name rule). */
function moduleNameOf(relativePath: string): string {
  return relativePath.replace(/\.ktr$/, "").replaceAll("/", ".");
}

/** The first capture group of every match of `pattern` in `text` (skipping any that failed to capture). */
function captures(text: string, pattern: RegExp): string[] {
  return [...text.matchAll(pattern)].flatMap((match) => (match[1] === undefined ? [] : [match[1]]));
}

/** Every `primitive agent NAME` declared across the stdlib, as its fully qualified `prelude.…` name.
 *  Comments and docstrings come out first (prose may begin a line with `primitive agent `), and what is
 *  left is anchored at column 0 — a top-level declaration is the only thing that can start a line there. */
function stdlibPrimitiveNames(): Set<string> {
  const names = new Set<string>();
  const subModulePaths = readdirSync(new URL("prelude/", stdlibDir)).map((name) => `prelude/${name}`);
  const relativePaths = ["prelude.ktr", ...subModulePaths].filter((path) => path.endsWith(".ktr"));
  for (const relativePath of relativePaths) {
    const module = moduleNameOf(relativePath);
    const source = withoutCommentsAndDocstrings(readFileSync(new URL(relativePath, stdlibDir), "utf8"));
    for (const name of captures(source, /^primitive agent ([A-Za-z0-9_]+)/gm)) {
      names.add(`${module}.${name}`);
    }
  }
  return names;
}

/** The `prelude.*` object keys registered in `prims.ts` / `interop-prims.ts` (a leading `"prelude.…":`
 *  key) and the host registrations in `host-prims.ts` (`prims.register("prelude.…"`). */
function runtimeRegisteredNames(): Set<string> {
  const names = new Set<string>();
  for (const file of ["prims.ts", "interop-prims.ts"]) {
    const source = readFileSync(new URL(file, engineDir), "utf8");
    for (const name of captures(source, /^\s*"(prelude\.[A-Za-z0-9_.]+)":/gm)) names.add(name);
  }
  const hostSource = readFileSync(new URL("host-prims.ts", engineDir), "utf8");
  for (const name of captures(hostSource, /prims\.register\(\s*"(prelude\.[A-Za-z0-9_.]+)"/g)) {
    names.add(name);
  }
  return names;
}

describe("stdlib primitives ↔ runtime registry", () => {
  const stdlib = stdlibPrimitiveNames();
  const runtime = runtimeRegisteredNames();

  // Guard against a broken parse silently reducing either set to nothing (which would make the
  // set-difference assertions vacuously pass). The stdlib currently declares 83 primitives.
  test("both sides parse a plausible number of names", () => {
    expect(stdlib.size).toBeGreaterThanOrEqual(80);
    expect(runtime.size).toBeGreaterThanOrEqual(80);
  });

  test("every stdlib `primitive agent` has a runtime implementation", () => {
    const missing = [...stdlib].filter((name) => !runtime.has(name)).sort();
    expect(missing).toEqual([]);
  });

  test("every registered runtime primitive is a declared stdlib `primitive agent`", () => {
    const extra = [...runtime].filter((name) => !stdlib.has(name)).sort();
    expect(extra).toEqual([]);
  });
});
