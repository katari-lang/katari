// Trip-wire: the reserved `$`-prefixed wire names are declared TWICE. The compiler EMITS them — the
// `$katari_*` keys of `Katari.Schema` (a data value's discriminator and nesting, a callable reference, a
// file handle and its semantic kind) and the `$generic` sentinel of `Katari.Data.JSONSchema` — and
// TypeScript READS them back: `wire.ts`'s exported key constants (the runtime codec and the FFI port
// share them) and the `$`-prefixed properties of `ir.ts`'s `JSONSchema` document type. Neither side can
// import the other's definition, so both are read from SOURCE TEXT and compared as name sets — the same
// shape as `runtime/test/reactor-names.test.ts`.
//
// Two things are checked, and both exist because the failure mode is silent: a renamed key produces
// valid-looking JSON that the other side simply never recognises.
//
//   1. The name SETS agree. A name that legitimately lives on one side only is listed below with its
//      reason, so adding a reserved key fails here until it is either mirrored or classified.
//   2. Every reserved name in the Haskell sources is bound to a NAMED CONSTANT. An inlined `"$katari_x"`
//      literal is what let the two sides drift in the first place; keeping the keys named is what makes
//      check 1 able to see them at all.

import { readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";

const repoRoot = new URL("../../../", import.meta.url);

/** The compiler sources that emit reserved wire names. */
const HASKELL_SOURCES = [
  "haskell/compiler/src/Katari/Schema.hs",
  "haskell/compiler/src/Katari/Data/JSONSchema.hs",
];

/** Reserved names TypeScript declares that the COMPILER never emits: the runtime's own value-wire
 *  vocabulary. The compiler describes a callable as the loose `$katari_agent` reference object and stops
 *  there — a closure / tool reference, its metadata, and the `redact` placeholder are minted by the
 *  runtime at execution time, never by a schema. */
const TYPESCRIPT_ONLY = new Set([
  "$katari_closure",
  "$katari_tool",
  "$katari_redacted",
  "$katari_snapshot",
  "$katari_generics",
  "$katari_scope_id",
  "$katari_module",
  "$katari_description",
  "$katari_input_schema",
  "$katari_output_schema",
  "$katari_reactor",
  "$katari_context",
  "$katari_naming",
]);

/** Reserved names the compiler emits that TypeScript declares nowhere. Empty on purpose: every key the
 *  compiler writes is a key some consumer must read back, so an entry here would be dead wire. */
const HASKELL_ONLY = new Set<string>();

function read(path: string): string {
  return readFileSync(new URL(path, repoRoot), "utf8");
}

/** Haskell source with its comments removed, so a `"$katari_ref"` quoted inside a Haddock example is not
 *  mistaken for a declaration (neither file uses `{- -}`, but both are stripped for good measure). */
function withoutHaskellComments(source: string): string {
  return source.replace(/\{-[\s\S]*?-\}/g, "").replace(/--.*$/gm, "");
}

/** Every `$`-prefixed string literal in a Haskell source, with comments stripped. */
function haskellKeyLiterals(source: string): string[] {
  return [...withoutHaskellComments(source).matchAll(/"(\$[A-Za-z0-9_]+)"/g)].flatMap((match) =>
    match[1] === undefined ? [] : [match[1]],
  );
}

/** Every `name = "$key"` top-level binding: the reserved names the compiler declares as constants. */
function haskellKeyConstants(source: string): string[] {
  return [
    ...withoutHaskellComments(source).matchAll(/^\w+\s*=\s*"(\$[A-Za-z0-9_]+)"\s*$/gm),
  ].flatMap((match) => (match[1] === undefined ? [] : [match[1]]));
}

/** The reserved names the compiler declares, across every source that emits one. */
function compilerKeys(): Set<string> {
  return new Set(HASKELL_SOURCES.flatMap((path) => haskellKeyConstants(read(path))));
}

/** The `export const NAME = "$katari_…"` key constants of `wire.ts`. */
function wireKeys(): Set<string> {
  const source = read("typescript/types/src/wire.ts");
  return new Set(
    [...source.matchAll(/^export const \w+(?::[^=]+)? = "(\$[A-Za-z0-9_]+)";$/gm)].flatMap((match) =>
      match[1] === undefined ? [] : [match[1]],
    ),
  );
}

/** The `$`-prefixed properties of `ir.ts`'s `JSONSchema` document type — where the schema sentinel the
 *  compiler writes is read back. Scoped to that one declaration so an unrelated `$` field cannot leak in. */
function schemaDocumentKeys(): Set<string> {
  const source = read("typescript/types/src/ir.ts");
  const declaration = /export type JSONSchema = \{([\s\S]*?)\n\};/.exec(source);
  if (declaration === null || declaration[1] === undefined) {
    throw new Error("could not find the `JSONSchema` type in ir.ts");
  }
  return new Set(
    [...declaration[1].matchAll(/^\s*(\$[A-Za-z0-9_]+)\??:/gm)].flatMap((match) =>
      match[1] === undefined ? [] : [match[1]],
    ),
  );
}

describe("reserved wire keys (Schema.hs / JSONSchema.hs ↔ wire.ts / ir.ts)", () => {
  const compiler = compilerKeys();
  const typescript = new Set([...wireKeys(), ...schemaDocumentKeys()]);

  test("both sides parse a plausible number of names", () => {
    // A broken regex must not vacuously pass the set diffs below.
    expect(compiler.size).toBeGreaterThanOrEqual(6);
    expect(typescript.size).toBeGreaterThanOrEqual(6);
  });

  test("every reserved name the compiler emits is declared on the TypeScript side", () => {
    const missing = [...compiler].filter((key) => !typescript.has(key) && !HASKELL_ONLY.has(key));
    expect(missing.sort()).toEqual([]);
  });

  test("every reserved name TypeScript declares is one the compiler emits", () => {
    const extra = [...typescript].filter((key) => !compiler.has(key) && !TYPESCRIPT_ONLY.has(key));
    expect(extra.sort()).toEqual([]);
  });

  test("the exclusion lists name only keys that still exist", () => {
    // A stale exemption is worse than none: it silently excuses a name nobody declares any more.
    expect([...TYPESCRIPT_ONLY].filter((key) => !typescript.has(key)).sort()).toEqual([]);
    expect([...HASKELL_ONLY].filter((key) => !compiler.has(key)).sort()).toEqual([]);
  });

  test("every reserved name in the compiler sources is bound to a named constant", () => {
    // The literal must appear ONLY in its own binding. An extra occurrence is a key written inline, which
    // is invisible to the comparison above and is exactly how the two sides drift apart unnoticed.
    for (const path of HASKELL_SOURCES) {
      const source = read(path);
      const constants = haskellKeyConstants(source);
      const literals = haskellKeyLiterals(source);
      expect({ path, literals: literals.slice().sort() }).toEqual({
        path,
        literals: constants.slice().sort(),
      });
    }
  });
});
