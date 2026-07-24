// Trip-wire: the set of external reactor names is hand-mirrored in two places — the compiler's
// `externalReactorNames` (`Katari.Typechecker.Check`), which the checker validates an `external ... from
// "name"` clause against (K3018), and the `ExternalReactorName` union in `@katari-lang/types`' `ir.ts`,
// which the runtime routes on. Both files say adding a reactor is "one edit here plus one in the other",
// so this checks the two lists agree. The `ExternalReactorName` union is a TYPE (erased at runtime), so
// neither side is a value we can import — both are read from source text and compared as string sets.

import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const repoRoot = new URL("../../../", import.meta.url);

/** Every double-quoted word in `text`, skipping any empty capture. */
function quotedWords(text: string): string[] {
  return [...text.matchAll(/"([^"]+)"/g)].flatMap((match) => (match[1] === undefined ? [] : [match[1]]));
}

/** The `["ffi", "http", ...]` list literal bound to `externalReactorNames` in Check.hs. */
function haskellReactorNames(): Set<string> {
  const source = readFileSync(
    new URL("haskell/compiler/src/Katari/Typechecker/Check.hs", repoRoot),
    "utf8",
  );
  const list = /externalReactorNames\s*=\s*\[([^\]]*)\]/.exec(source);
  if (list === null || list[1] === undefined) {
    throw new Error("could not find `externalReactorNames` in Check.hs");
  }
  return new Set(quotedWords(list[1]));
}

/** The `"ffi" | "http" | ...` string-literal union of `ExternalReactorName` in ir.ts. */
function typescriptReactorNames(): Set<string> {
  const source = readFileSync(new URL("typescript/types/src/ir.ts", repoRoot), "utf8");
  const union = /export type ExternalReactorName\s*=\s*([^;]+);/.exec(source);
  if (union === null || union[1] === undefined) {
    throw new Error("could not find `ExternalReactorName` in ir.ts");
  }
  return new Set(quotedWords(union[1]));
}

describe("external reactor names (Check.hs ↔ ir.ts)", () => {
  const haskell = haskellReactorNames();
  const typescript = typescriptReactorNames();

  test("both sides parse a plausible number of names", () => {
    // "ffi" plus the stdlib-only reactors — a broken parse must not vacuously pass the diffs below.
    expect(haskell.size).toBeGreaterThanOrEqual(5);
    expect(typescript.size).toBeGreaterThanOrEqual(5);
  });

  test("every compiler reactor name is in the runtime's ExternalReactorName union", () => {
    const missing = [...haskell].filter((name) => !typescript.has(name)).sort();
    expect(missing).toEqual([]);
  });

  test("every ExternalReactorName is a name the compiler accepts", () => {
    const extra = [...typescript].filter((name) => !haskell.has(name)).sort();
    expect(extra).toEqual([]);
  });
});
