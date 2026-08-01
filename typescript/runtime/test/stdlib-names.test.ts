// Trip-wire: every `prelude.…` name the runtime SPELLS must be a name the stdlib DECLARES.
//
// `stdlib-prim-registry.test.ts` covers the `primitive agent` names, and `reactor-names.test.ts` covers
// the external reactor names; both explicitly leave the rest alone. This closes that gap for the two
// vocabularies the runtime hand-writes most:
//
//   * the 19 `external agent` DISPATCH KEYS — the compiled external's rendered qualified name, which each
//     call reactor compares exactly at its payload boundary (`MCP_PROVIDE_KEY`, `REGION_FORK_KEY`,
//     `FETCH_FILE_KEY`, …). A key that does not match falls into the reactor's defensive arm, so a rename
//     surfaces only as an "unimplemented" completion deep inside a run;
//   * the ~25 `data` CONSTRUCTOR names the reactors and prims BUILD their replies out of
//     (`prelude.store.found`, `prelude.http.text`, `prelude.region.fiber_info`,
//     `prelude.mcp.server_error`, …). A stale ctor name produces a value no Katari `match` arm can ever
//     select — a silent wrong answer rather than an error.
//
// Both sides are read from source text: the stdlib is Katari, and the runtime's names are scattered
// across module-level constants, object keys and inline literals with no single value to enumerate. The
// runtime scan takes only DOUBLE-QUOTED literals whose whole content is a `prelude.…` name, so prose in
// the (very numerous) comments and partial names like `prelude.mcp.*` never enter the set.
//
// The directions are not symmetric:
//   * runtime → stdlib is a HARD failure. A name the runtime spells that nothing declares is drift, full
//     stop (modulo the two runtime-authored requests below, which have no declaration by design).
//   * stdlib → runtime is asserted only for `external agent`s, which by definition need a reactor to
//     serve them. `data` ctors are NOT: most of the stdlib's 54 are pure Katari the runtime never names.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { PANIC_REQUEST } from "../src/runtime/engine/common.js";
import { OAUTH_AUTHORIZE_REQUEST } from "../src/runtime/external/credentials.js";
import { withoutCommentsAndDocstrings } from "./katari-source.js";

const stdlibDirectory = new URL("../../../haskell/compiler/stdlib/", import.meta.url);
const runtimeSourceDirectory = new URL("../src/", import.meta.url);

/** The declaration forms that introduce a name the RUNTIME can legitimately spell on the wire. `type` and
 *  `effect` are excluded on purpose: they are compile-time only, so a runtime literal naming one is drift
 *  exactly as an undeclared name is. Ordered longest-first, since the alternation is matched in order. */
const DECLARATION_FORMS = "primitive agent|external agent|agent|request|data";

/** The `prelude.…` names the RUNTIME authors and the stdlib deliberately does not declare — each a request
 *  a program can neither perform nor handle, so there is nothing for the stdlib to expose:
 *   - `prelude.panic`: the runtime's own defect signal (a prim failure, a non-exhaustive match, an FFI
 *     error). See `PANIC_REQUEST` in `engine/common.ts`.
 *   - `prelude.oauth.authorize`: the credential-park escalation a reactor raises on the caller's behalf
 *     and an operator answers by completing the runtime-hosted flow. See `external/credentials.ts`.
 *  Anything else appearing here is drift, not a new convention. */
const RUNTIME_AUTHORED_NAMES = new Set<string>([PANIC_REQUEST, OAUTH_AUTHORIZE_REQUEST]);

/** The `external agent`s no runtime literal names, because their reactor tells the operation apart
 *  POSITIONALLY rather than by key — each with the reason it needs no name:
 *   - `prelude.http.fetch`: the http reactor compares only `FETCH_FILE_KEY`; every other key (i.e. this
 *     one) takes the text-response arm.
 *   - `prelude.webhook.inbound`: the webhook reactor serves exactly one operation, so its payload
 *     boundary has nothing to discriminate.
 *  A new external landing here silently would mean a reactor that never routes it, so the list is
 *  spelled out rather than inferred. */
const POSITIONALLY_DISPATCHED_EXTERNALS = new Set<string>([
  "prelude.http.fetch",
  "prelude.webhook.inbound",
]);

/** The module prefix a stdlib `.ktr` file lowers under: `prelude.ktr` → `prelude`, `prelude/mcp.ktr` →
 *  `prelude.mcp` (the compiler's own path-to-module-name rule). */
function moduleNameOf(relativePath: string): string {
  return relativePath.replace(/\.ktr$/, "").replaceAll("/", ".");
}

/** Every top-level stdlib declaration, as its fully qualified name mapped to the form that introduced it.
 *  Comments and docstrings come out first (prose may begin a line with a declaration form), and what is
 *  left is anchored at column 0, so a handler implementation nested inside a `use handler` is skipped too
 *  — only declarations are collected. */
function stdlibDeclarations(): Map<string, string> {
  const declarations = new Map<string, string>();
  const subModulePaths = readdirSync(new URL("prelude/", stdlibDirectory)).map(
    (name) => `prelude/${name}`,
  );
  const relativePaths = ["prelude.ktr", ...subModulePaths].filter((path) => path.endsWith(".ktr"));
  const pattern = new RegExp(`^(${DECLARATION_FORMS}) ([A-Za-z0-9_]+)`, "gm");
  for (const relativePath of relativePaths) {
    const module = moduleNameOf(relativePath);
    const source = withoutCommentsAndDocstrings(
      readFileSync(new URL(relativePath, stdlibDirectory), "utf8"),
    );
    for (const match of source.matchAll(pattern)) {
      const [, form, name] = match;
      if (form !== undefined && name !== undefined) declarations.set(`${module}.${name}`, form);
    }
  }
  return declarations;
}

/** Every `.ts` file under a directory, recursively. */
function typescriptFilesUnder(directory: URL): URL[] {
  const files: URL[] = [];
  for (const entry of readdirSync(directory)) {
    const path = new URL(entry, directory);
    if (statSync(fileURLToPath(path)).isDirectory()) {
      files.push(...typescriptFilesUnder(new URL(`${entry}/`, directory)));
    } else if (entry.endsWith(".ts")) {
      files.push(path);
    }
  }
  return files;
}

/** Every `prelude.…` name spelled as a whole double-quoted string literal in the runtime's source, mapped
 *  to the files that spell it (so a failure names where to look). */
function runtimeSpelledNames(): Map<string, string[]> {
  const names = new Map<string, string[]>();
  for (const file of typescriptFilesUnder(runtimeSourceDirectory)) {
    const relativePath = fileURLToPath(file).slice(fileURLToPath(runtimeSourceDirectory).length);
    for (const match of readFileSync(file, "utf8").matchAll(/"(prelude\.[A-Za-z0-9_.]+)"/g)) {
      const name = match[1];
      if (name === undefined) continue;
      const sites = names.get(name);
      if (sites === undefined) names.set(name, [relativePath]);
      else if (!sites.includes(relativePath)) sites.push(relativePath);
    }
  }
  return names;
}

describe("stdlib declarations ↔ the names the runtime spells", () => {
  const declarations = stdlibDeclarations();
  const spelled = runtimeSpelledNames();
  const externals = new Set(
    [...declarations].filter(([, form]) => form === "external agent").map(([name]) => name),
  );
  const dataConstructors = new Set(
    [...declarations].filter(([, form]) => form === "data").map(([name]) => name),
  );

  // Guard against a broken parse silently reducing either side to nothing, which would make the
  // set-difference assertions vacuously pass. The stdlib currently declares 224 names (19 of them
  // `external agent`, 54 of them `data`), and the runtime spells 142 of them.
  test("both sides parse a plausible number of names", () => {
    expect(declarations.size).toBeGreaterThanOrEqual(200);
    expect(externals.size).toBeGreaterThanOrEqual(18);
    expect(dataConstructors.size).toBeGreaterThanOrEqual(50);
    expect(spelled.size).toBeGreaterThanOrEqual(120);
    // The `data` ctor names are the half with no other guard at all — pin that the runtime really does
    // build its replies out of the stdlib's constructors, so the check below is not covering an empty set.
    expect([...spelled.keys()].filter((name) => dataConstructors.has(name)).length).toBeGreaterThanOrEqual(24);
  });

  test("every `prelude.…` name the runtime spells is declared by the stdlib", () => {
    const undeclared = [...spelled]
      .filter(([name]) => !declarations.has(name) && !RUNTIME_AUTHORED_NAMES.has(name))
      .map(([name, sites]) => `${name} (${sites.join(", ")})`)
      .sort();
    expect(undeclared).toEqual([]);
  });

  test("every runtime-authored name is genuinely undeclared", () => {
    // Keeps the exemption list honest: once the stdlib declares one of these, it stops being an exemption
    // and the check above should be enforcing it like any other name.
    const nowDeclared = [...RUNTIME_AUTHORED_NAMES].filter((name) => declarations.has(name)).sort();
    expect(nowDeclared).toEqual([]);
  });

  test("every stdlib `external agent` is a dispatch key the runtime names", () => {
    const unrouted = [...externals]
      .filter((name) => !spelled.has(name) && !POSITIONALLY_DISPATCHED_EXTERNALS.has(name))
      .sort();
    expect(unrouted).toEqual([]);
  });

  test("every positionally-dispatched external is a declared external the runtime does not name", () => {
    // The mirror of the check above: an entry that stops being needed (its reactor grew a real key) or
    // stops existing must be removed rather than left as dead cover.
    const stale = [...POSITIONALLY_DISPATCHED_EXTERNALS]
      .filter((name) => !externals.has(name) || spelled.has(name))
      .sort();
    expect(stale).toEqual([]);
  });
});
