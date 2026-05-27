// Sidecar bundler. Each input is a `{ packageName, sourceRoot }` pair —
// one package's source tree. The bundler walks the source root for a
// single `.ts` / `.js` file (anywhere under the root; nesting is not
// inherently forbidden but having more than one sidecar in the same
// package is a hard error) and packs every package's sidecar into a
// single ESM bundle that imports `katari-port`.
//
// The generated entry wires each package through
// `__withModule(packageName, body)` so `katari.agent(localName, ...)`
// calls register under the **flat** key `<packageName>.<localName>` —
// completely independent of the sidecar file's path within the package.
// The bundle ends with `__startSidecar()` to hand stdio control over to
// katari-port.

import { build, type Plugin } from "esbuild";
import { init as initLexer, parse as parseLexer } from "es-module-lexer";
import { readdir, readFile, stat } from "node:fs/promises";
import { extname, join } from "node:path";
import type { SidecarBundle } from "@katari-lang/runtime";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

export interface BundlePackage {
  /**
   * Package name from `katari.toml` (e.g. `"ext_agent"`). Used as the
   * flat prefix for every `katari.agent(name, ...)` registration in the
   * package's sidecar — the bundle registers them under
   * `<packageName>.<name>`.
   */
  packageName: string;
  /**
   * Absolute path of the package's source root (typically
   * `<packageRoot>/src`). The bundler walks it for the single sidecar
   * `.ts` / `.js` file.
   */
  sourceRoot: string;
}

export interface BundleOptions {
  /** One entry per katari package whose sidecar (if any) should be bundled. */
  packages: BundlePackage[];
}

export interface BundleResult {
  bundle: SidecarBundle;
  /** Package names whose sidecars were included in the bundle. */
  modules: string[];
}

/**
 * Bundle every package's sidecar into one ESM bundle. Returns `null`
 * when no package has a sidecar (= the snapshot doesn't need a sidecar
 * runtime). Each package is allowed at most one `.ts` / `.js` file under
 * its source root; more than one is a hard error.
 */
export async function bundleSidecar(
  opts: BundleOptions,
): Promise<BundleResult | null> {
  const entries = await collectSiblingEntries(opts.packages);
  if (entries.length === 0) return null;

  const syntheticEntry = renderSyntheticEntry(entries);

  const moduleWrapPlugin = makeModuleWrapPlugin(entries);

  let result: Awaited<ReturnType<typeof build>> | undefined;
  try {
    result = await build({
      stdin: {
        contents: syntheticEntry,
        resolveDir: opts.packages[0]?.sourceRoot ?? process.cwd(),
        loader: "ts",
        sourcefile: "<katari-sidecar-entry>",
      },
      bundle: true,
      format: "esm",
      platform: "node",
      target: "node20",
      write: false,
      sourcemap: false,
      treeShaking: true,
      plugins: [moduleWrapPlugin],
    });
  } catch (err) {
    throw new BundleError(
      `failed to bundle sidecar: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
  }
  if (result.outputFiles === undefined || result.outputFiles.length === 0) {
    throw new BundleError("esbuild produced no output for sidecar bundle");
  }
  const bundle: SidecarBundle = {
    entry: result.outputFiles[0]!.text,
    runtime: "node",
    schemaVersion: 1,
  };
  return {
    bundle,
    modules: entries.map((e) => e.moduleQname),
  };
}

// ─── Sidecar discovery ─────────────────────────────────────────────────────

interface SiblingEntry {
  /** Absolute path of the sidecar JS / TS source. */
  siblingPath: string;
  /** Module qualified name (= package name, flat). */
  moduleQname: string;
}

/**
 * For each package, find the single sidecar file under its source root.
 * Returns one entry per package that has a sidecar (packages with none
 * are silently skipped — they're katari-only). Throws when a package
 * has more than one `.ts` / `.js` file under its source root.
 */
async function collectSiblingEntries(
  packages: BundlePackage[],
): Promise<SiblingEntry[]> {
  const out: SiblingEntry[] = [];
  for (const pkg of packages) {
    const exists = await pathExists(pkg.sourceRoot);
    if (!exists) continue;
    const sidecars = await walkSidecars(pkg.sourceRoot);
    if (sidecars.length === 0) continue;
    if (sidecars.length > 1) {
      throw new BundleError(
        `package "${pkg.packageName}" has ${sidecars.length} sidecar files under ${pkg.sourceRoot}:\n  - ${sidecars.join(
          "\n  - ",
        )}\nEach katari package may register at most one sidecar file (Wave 6b-A3 flat-bundle rule). Combine them into one ts/js file.`,
      );
    }
    out.push({ siblingPath: sidecars[0]!, moduleQname: pkg.packageName });
  }
  // Deterministic order for reproducible bundles.
  out.sort((a, b) => (a.moduleQname < b.moduleQname ? -1 : 1));
  return out;
}

/**
 * Walk a directory for `.ts` / `.js` files, treating both `foo.ts` and
 * `foo.js` for the same basename as one sidecar (the JS variant is the
 * compiled output of the TS source). Throws if both exist with the same
 * basename in the same directory.
 */
async function walkSidecars(root: string): Promise<string[]> {
  const tsFiles = await walkFiles(root, ".ts");
  const jsFiles = await walkFiles(root, ".js");
  const byBasename = new Map<string, string>();
  for (const p of tsFiles) {
    byBasename.set(noExtKey(p), p);
  }
  for (const p of jsFiles) {
    const key = noExtKey(p);
    if (byBasename.has(key)) {
      throw new BundleError(
        `both ${byBasename.get(key)!} and ${p} exist — keep only one`,
      );
    }
    byBasename.set(key, p);
  }
  return [...byBasename.values()].sort();
}

async function walkFiles(root: string, ext: string): Promise<string[]> {
  const out: string[] = [];
  const stack: string[] = [root];
  while (stack.length > 0) {
    const dir = stack.pop()!;
    const dirents = await readdir(dir, { withFileTypes: true });
    for (const dirent of dirents) {
      const full = join(dir, dirent.name);
      if (dirent.isDirectory()) {
        stack.push(full);
      } else if (dirent.isFile() && extname(dirent.name) === ext) {
        out.push(full);
      }
    }
  }
  return out;
}

function noExtKey(path: string): string {
  // Strip the .ts / .js extension to group TS/JS variants of the same
  // sidecar together.
  return path.replace(/\.(ts|js)$/, "");
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await stat(p);
    return true;
  } catch {
    return false;
  }
}

// ─── Synthetic entry ───────────────────────────────────────────────────────

function renderSyntheticEntry(entries: SiblingEntry[]): string {
  // Import each user module via its absolute path so esbuild bundles
  // its body. Each import is preceded by a __withModule call to set
  // the module qname; the module-wrap plugin pushes/pops qname around
  // the file body so katari.agent(name, ...) registers under
  // `<qname>.<name>`.
  const importLines = entries
    .map((e, idx) =>
      `import "${escapeJsonPath(e.siblingPath)}";  // module ${idx}: ${e.moduleQname}`,
    )
    .join("\n");

  return [
    `// Auto-generated synthetic entry for katari-sidecar bundle.`,
    `import { __startSidecar } from "@katari-lang/port";`,
    importLines,
    `__startSidecar();`,
    ``,
  ].join("\n");
}

function escapeJsonPath(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

// ─── Module-wrap plugin ────────────────────────────────────────────────────
//
// For each sibling source file, the plugin wraps the *body* (= non-import
// statements) in `__withModule("qname", () => { ...body... })` so that
// `katari.agent(localName, handler)` inside resolves to
// `<qname>.<localName>` in the katari-port registry. Top-level imports
// stay outside the wrapper (ESM rules them illegal inside a function).

function makeModuleWrapPlugin(entries: SiblingEntry[]): Plugin {
  const pathToQname = new Map(
    entries.map((e) => [e.siblingPath, e.moduleQname] as const),
  );
  return {
    name: "katari-module-wrap",
    setup(build) {
      build.onLoad({ filter: /\.(ts|js)$/ }, async (args) => {
        const qname = pathToQname.get(args.path);
        if (qname === undefined) return null; // not a tracked sibling
        const raw = await readFile(args.path, "utf8");
        const { imports, body } = await splitTopLevelImports(raw);
        const loader: "ts" | "js" = args.path.endsWith(".ts") ? "ts" : "js";
        const wrapped =
          `${imports}\n` +
          `;(globalThis as any).__withModule(${JSON.stringify(qname)}, () => {\n` +
          `${body}\n` +
          `});\n`;
        return { contents: wrapped, loader };
      });
    },
  };
}

/**
 * Extract top-level static imports using es-module-lexer (a real ES
 * tokenizer) rather than regex over lines. Returns the original source
 * split into `imports` (the verbatim import statements concatenated) and
 * `body` (everything else). String literals, template literals, and
 * comments are correctly skipped so a payload like
 *
 *     // import { x } from "y";
 *     `import { z } from "w"`;
 *
 * is treated as body, not as imports. Dynamic imports (`import(...)`)
 * are left in the body.
 *
 * The lexer is async-init; callers must `await initLexer` once before
 * the first call. We do that on every invocation — `init` is idempotent
 * and the cost amortises trivially across a build.
 */
async function splitTopLevelImports(source: string): Promise<{
  imports: string;
  body: string;
}> {
  await initLexer;
  const [staticImports] = parseLexer(source);
  if (staticImports.length === 0) {
    return { imports: "", body: source };
  }

  // es-module-lexer gives statement-start (ss) and statement-end (se)
  // offsets for each import. Slice them out of the source into
  // `imports`, replace each occupied range in the body with a blank of
  // the same length so source positions in the body don't shift (= keeps
  // any sourcemap-ish reasoning intact).
  const importChunks: string[] = [];
  let body = source;
  // Iterate in reverse so substring positions stay valid as we splice.
  for (let i = staticImports.length - 1; i >= 0; i--) {
    const imp = staticImports[i]!;
    // ss/se are character offsets including the trailing semicolon when
    // present. Dynamic imports report d >= 0 and we skip them.
    if (imp.d !== -1) continue;
    const chunk = source.slice(imp.ss, imp.se);
    importChunks.unshift(chunk);
    body = body.slice(0, imp.ss) + " ".repeat(imp.se - imp.ss) + body.slice(imp.se);
  }
  return {
    imports: importChunks.join("\n"),
    body,
  };
}
