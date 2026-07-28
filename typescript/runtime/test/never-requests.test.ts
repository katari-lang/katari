// Trip-wire: the failure-channel name list in `escalation-filter.ts` must match the stdlib's `-> never`
// requests exactly.
//
// `isFailureRequest` is what keeps a failure row out of every user-facing read (the api reactor's
// answerable set, `katari ls escalations`, the run-tree's answerable mark). The general rule behind it is
// structural — a request whose DECLARED result is `never` has no valid answer, so it can only be a failure
// channel — but the runtime deliberately does NOT generalise: it names the two stdlib requests instead
// (see the `isFailureRequest` doc comment for why the generalisation was declined). A name list drifts, so
// this test is the guard: it reads every top-level `request NAME(...) -> never` out of the stdlib source
// and compares that set to the names the filter treats as failures.
//
// A THIRD stdlib `-> never` request therefore fails here rather than silently becoming an un-answerable
// escalation parked at the run root, and the failure forces the choice: add it to the filter's list, or
// intend it to be user-facing.
//
// `prelude.panic` is the ONE deliberate asymmetry: the runtime's own defect signal, raised by the engine
// and never declared in the stdlib (a program can neither raise nor handle it — see `PANIC_REQUEST` in
// `engine/common.ts`). It is a failure channel with no declaration to match, so it is excluded by name
// below and asserted separately, rather than left to be noticed as a diff.

import { readdirSync, readFileSync } from "node:fs";
import { describe, expect, test } from "vitest";
import { PANIC_REQUEST } from "../src/runtime/engine/common.js";
import { THROW_REQUEST } from "../src/runtime/engine/throw-signal.js";
import { isFailureRequest, REPLAY_INTERRUPTED_REQUEST } from "../src/runtime/escalation-filter.js";

const stdlibDirectory = new URL("../../../haskell/compiler/stdlib/", import.meta.url);

/** The module prefix a stdlib `.ktr` file lowers under: `prelude.ktr` → `prelude`, `prelude/replay.ktr`
 *  → `prelude.replay` (the compiler's own path-to-module-name rule). */
function moduleNameOf(relativePath: string): string {
  return relativePath.replace(/\.ktr$/, "").replaceAll("/", ".");
}

/** Every stdlib `.ktr` file, as a path relative to the stdlib root. */
function stdlibRelativePaths(): string[] {
  const subModulePaths = readdirSync(new URL("prelude/", stdlibDirectory)).map(
    (name) => `prelude/${name}`,
  );
  return ["prelude.ktr", ...subModulePaths].filter((path) => path.endsWith(".ktr"));
}

/**
 * The leading token of the result type declared after the parameter list starting at `start`, or `null`
 * when the head does not parse.
 *
 * The scan balances parentheses and skips string literals, because neither the first `->` nor the first
 * `)` after the name is reliable: a parameter can be an agent type carrying its own arrow (`task: agent
 * (value: null) -> unknown`), and a docstring can carry either character inside quotes. An optional
 * generic list precedes the parameters and holds no parentheses in any stdlib declaration, so skipping to
 * its `]` is enough.
 */
function resultTypeAfter(source: string, start: number): string | null {
  let index = start;
  while (index < source.length && /\s/.test(source[index] ?? "")) index++;
  if (source[index] === "[") {
    const close = source.indexOf("]", index);
    if (close === -1) return null;
    index = close + 1;
  }
  while (index < source.length && /\s/.test(source[index] ?? "")) index++;
  if (source[index] === "(") {
    let depth = 0;
    let inString = false;
    for (; index < source.length; index++) {
      const character = source[index];
      if (inString) {
        if (character === "\\") index++;
        else if (character === '"') inString = false;
        continue;
      }
      if (character === '"') inString = true;
      else if (character === "(") depth++;
      else if (character === ")") {
        depth--;
        if (depth === 0) {
          index++;
          break;
        }
      }
    }
    if (depth !== 0) return null;
  }
  return /^\s*->\s*([A-Za-z0-9_]+)/.exec(source.slice(index))?.[1] ?? null;
}

/** Every TOP-LEVEL `request` declared across the stdlib, as its fully qualified name paired with the
 *  leading token of its result type. Anchored at column 0 so a handler IMPLEMENTATION (`request throw(…)
 *  -> never { … }`, always indented inside a `use handler`) and a docstring mention are both skipped —
 *  only declarations are collected. */
function stdlibRequests(): Map<string, string | null> {
  const requests = new Map<string, string | null>();
  for (const relativePath of stdlibRelativePaths()) {
    const module = moduleNameOf(relativePath);
    const source = readFileSync(new URL(relativePath, stdlibDirectory), "utf8");
    for (const match of source.matchAll(/^request ([A-Za-z0-9_]+)/gm)) {
      const name = match[1];
      if (name === undefined || match.index === undefined) continue;
      requests.set(`${module}.${name}`, resultTypeAfter(source, match.index + match[0].length));
    }
  }
  return requests;
}

/** The failure channels the filter names, minus `prelude.panic` (undeclared by design — see the header). */
const declaredFailureRequests = new Set<string>([THROW_REQUEST, REPLAY_INTERRUPTED_REQUEST]);

describe("stdlib `-> never` requests ↔ the escalation filter's failure set", () => {
  const requests = stdlibRequests();
  const neverRequests = new Set(
    [...requests].filter(([, result]) => result === "never").map(([name]) => name),
  );

  test("the stdlib parse finds a plausible number of requests", () => {
    // The stdlib currently declares 15 top-level requests, two of which answer `never`. A broken parse
    // must not reduce either set to nothing and vacuously pass the diffs below.
    expect(requests.size).toBeGreaterThanOrEqual(12);
    expect(neverRequests.size).toBeGreaterThanOrEqual(2);
    // Nothing may parse to an unknown result type: a declaration the scanner could not read would be
    // silently dropped from `neverRequests`.
    expect([...requests].filter(([, result]) => result === null).map(([name]) => name)).toEqual([]);
  });

  test("every stdlib `-> never` request is a failure channel the filter knows", () => {
    const missing = [...neverRequests].filter((name) => !declaredFailureRequests.has(name)).sort();
    expect(missing).toEqual([]);
  });

  test("every named failure channel is a declared stdlib `-> never` request", () => {
    const extra = [...declaredFailureRequests].filter((name) => !neverRequests.has(name)).sort();
    expect(extra).toEqual([]);
  });

  test("`isFailureRequest` actually classifies each named channel as a failure", () => {
    // The two sets above are constants; this pins them to the PREDICATE, so a name that stops being read
    // by `isFailureRequest` cannot pass the diffs on the strength of still being exported.
    for (const name of declaredFailureRequests) expect(isFailureRequest(name)).toBe(true);
  });

  test("`prelude.panic` is a failure channel the stdlib deliberately does not declare", () => {
    expect(isFailureRequest(PANIC_REQUEST)).toBe(true);
    expect(requests.has(PANIC_REQUEST)).toBe(false);
  });
});
