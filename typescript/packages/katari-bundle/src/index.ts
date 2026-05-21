// Sidecar bundler. Walks one or more `sourceRoots` to find `.ktr` files
// with sibling `.js` / `.ts` (= ext-agent implementations), and packs
// them into a single ESM bundle that imports `katari-port`.
//
// The generated entry wires each user module through `__withModule(qname, body)`
// so katari.agent(localName, ...) calls register under the qualified key
// `<module qname>.<localName>`. The bundle ends with `__startSidecar()`
// to hand stdio control over to katari-port.

import { build, type Plugin } from "esbuild";
import { init as initLexer, parse as parseLexer } from "es-module-lexer";
import { readdir, readFile, stat } from "node:fs/promises";
import { dirname, extname, join, relative, sep } from "node:path";
import type { SidecarBundle } from "@katari-lang/runtime";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

export interface BundleOptions {
  /**
   * Absolute paths of directories to walk for ext-agent siblings.
   * `foo.ktr` adjacent to `foo.js` or `foo.ts` (exactly one) under any
   * of these roots is included in the bundle.
   */
  sourceRoots: string[];
}

export interface BundleResult {
  bundle: SidecarBundle;
  /** Module qnames discovered, e.g. `"main"`, `"tools.http"`. */
  modules: string[];
}

/**
 * Bundle every ext-agent sibling under `sourceRoots` into one ESM bundle.
 * Returns `null` when no sibling JS/TS files are found (= the snapshot
 * doesn't need a sidecar).
 */
export async function bundleSidecar(
  opts: BundleOptions,
): Promise<BundleResult | null> {
  const entries = await collectSiblingEntries(opts.sourceRoots);
  if (entries.length === 0) return null;

  const syntheticEntry = renderSyntheticEntry(entries);

  const moduleWrapPlugin = makeModuleWrapPlugin(entries);

  let result;
  try {
    result = await build({
      stdin: {
        contents: syntheticEntry,
        resolveDir: opts.sourceRoots[0] ?? process.cwd(),
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

// ─── Sibling discovery ─────────────────────────────────────────────────────

interface SiblingEntry {
  /** Absolute path of the sibling JS / TS source. */
  siblingPath: string;
  /** Module qualified name (= dotted path relative to the sourceRoot). */
  moduleQname: string;
}

async function collectSiblingEntries(
  sourceRoots: string[],
): Promise<SiblingEntry[]> {
  const out: SiblingEntry[] = [];
  for (const root of sourceRoots) {
    const exists = await pathExists(root);
    if (!exists) continue;
    for (const ktrPath of await walkFiles(root, ".ktr")) {
      const dir = dirname(ktrPath);
      const baseNoExt = basenameNoExt(ktrPath);
      const candidateTs = join(dir, `${baseNoExt}.ts`);
      const candidateJs = join(dir, `${baseNoExt}.js`);
      const hasTs = await pathExists(candidateTs);
      const hasJs = await pathExists(candidateJs);
      if (hasTs && hasJs) {
        throw new BundleError(
          `both ${candidateTs} and ${candidateJs} exist next to ${ktrPath} — keep only one`,
        );
      }
      if (!hasTs && !hasJs) continue;
      const sibling = hasTs ? candidateTs : candidateJs;
      const relFromRoot = relative(root, sibling);
      // Path components that themselves contain `.` would collide with
      // the dotted module-qname separator (e.g. `v1.2/foo.ts` → qname
      // `v1.2.foo`, indistinguishable from a hypothetical `v1/2/foo.ts`).
      // Reject at discovery time so the conflict surfaces at apply
      // time with a clear message.
      const segments = relFromRoot.split(/[\\/]/g).filter((s) => s.length > 0);
      const noExt = segments.map((s, i) =>
        i === segments.length - 1 ? s.replace(/\.(ts|js)$/, "") : s,
      );
      for (const seg of noExt) {
        if (seg.includes(".")) {
          throw new BundleError(
            `path segment '${seg}' in ${sibling} contains '.' — module qnames use '.' as the segment separator. Rename the offending directory or file.`,
          );
        }
      }
      const moduleQname = pathToQname(relFromRoot);
      out.push({ siblingPath: sibling, moduleQname });
    }
  }
  // Deterministic order for reproducible bundles.
  out.sort((a, b) => (a.moduleQname < b.moduleQname ? -1 : 1));
  return out;
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

function basenameNoExt(path: string): string {
  const idx = path.lastIndexOf(sep);
  const base = idx === -1 ? path : path.slice(idx + 1);
  const dot = base.lastIndexOf(".");
  return dot === -1 ? base : base.slice(0, dot);
}

function pathToQname(relPath: string): string {
  // Drop extension and split on path separator.
  const noExt = relPath.replace(/\.(ts|js)$/, "");
  return noExt.split(/[\\/]/g).filter((s) => s.length > 0).join(".");
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
