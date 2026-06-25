// FFI sidecar bundler. Each input is a `{ packageName, sourceRoot }` pair — one package's sidecar source
// tree. Every sidecar file is equal (each just registers some agents), so there is no privileged entry: the
// bundler generates its own entry that imports every `.ts`/`.js` file under each package's root, and esbuild
// packs them into a single ESM bundle that hands stdio control to `@katari-lang/port` via `__startSidecar()`.
//
// Each package source file is prefixed with `globalThis.__katariModule = "<packageName>"`, so a
// `katari.agent(localName, ...)` it runs registers under the flat key `<packageName>.<localName>` — exactly
// the key the compiler lowers an `external agent` to. A plain prepended assignment (not a function wrapper)
// runs before the file body yet keeps the file's own imports and exports legal at the module top level, so
// a package can split its sidecar across several files that import/export from one another.

import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { extname, join, resolve, sep } from "node:path";
import type { SidecarBundle } from "@katari-lang/types";
import { build, type Plugin } from "esbuild";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

export interface BundlePackage {
  /** Package name from `katari.toml`. The flat prefix every `katari.agent(name)` in this package's
   *  sidecar registers under (`<packageName>.<name>`), matching the compiler's external dispatch key. */
  packageName: string;
  /** Path of the package's sidecar source root. The entry is `<packageName>.{ts,js}` here (or the sole
   *  top-level `.ts`/`.js` file); esbuild follows its imports for the rest. */
  sourceRoot: string;
}

export interface BundleOptions {
  /** One entry per katari package whose sidecar (if any) should be bundled. */
  packages: BundlePackage[];
}

/**
 * Bundle every package's sidecar into one ESM bundle, or `null` when no package has a sidecar (the
 * snapshot needs no FFI runtime). Throws `BundleError` on a malformed package layout or an esbuild failure.
 */
export async function bundleSidecar(options: BundleOptions): Promise<SidecarBundle | null> {
  const sources = await resolveSources(options.packages);
  if (sources.length === 0) return null;
  return { entry: await runEsbuild(sources), runtime: "node" };
}

// ─── Source discovery ──────────────────────────────────────────────────────

interface PackageSource {
  packageName: string;
  /** Absolute source root with a trailing separator, so a prefix test for "is this file in the package"
   *  cannot match a sibling like `<root>-other`. */
  root: string;
  /** Every sidecar source file under `root` (sorted), each imported by the synthetic entry. */
  files: string[];
}

/** Collect every package's sidecar source files, skipping packages with no sidecar source. Sorted by name
 *  for a reproducible bundle. */
async function resolveSources(packages: BundlePackage[]): Promise<PackageSource[]> {
  const sources: PackageSource[] = [];
  for (const pkg of packages) {
    const resolved = resolve(pkg.sourceRoot);
    if (!(await isDirectory(resolved))) continue; // the package has no sidecar source at all
    // Canonicalize symlinks (e.g. macOS `/var` → `/private/var`) so the plugin's "is this file inside the
    // package" prefix test matches esbuild's own realpath'd `args.path`.
    const root = await realpath(resolved);
    const files = await collectSourceFiles(root);
    if (files.length === 0) continue; // a source dir with no .ts/.js sidecar — nothing to bundle
    sources.push({ packageName: pkg.packageName, root: root + sep, files });
  }
  sources.sort((a, b) => (a.packageName < b.packageName ? -1 : 1));
  return sources;
}

/** Every `.ts`/`.js` file under `root` (recursively), sorted for a reproducible bundle. Type-declaration
 *  files (`.d.ts`) are skipped — they carry no runtime code to register. */
async function collectSourceFiles(root: string): Promise<string[]> {
  const files: string[] = [];
  const directories = [root];
  for (let directory = directories.pop(); directory !== undefined; directory = directories.pop()) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const full = join(directory, entry.name);
      if (entry.isDirectory()) directories.push(full);
      else if (entry.isFile() && isSourceFile(entry.name)) files.push(full);
    }
  }
  return files.sort();
}

function isSourceFile(name: string): boolean {
  if (name.endsWith(".d.ts")) return false; // a type-declaration file, not a runtime module
  return extname(name) === ".ts" || extname(name) === ".js";
}

// ─── esbuild ─────────────────────────────────────────────────────────────

async function runEsbuild(sources: PackageSource[]): Promise<string> {
  // The caller only reaches here with at least one package; resolve the synthetic entry's relative imports
  // against the first package's directory.
  const [first] = sources;
  if (first === undefined) throw new BundleError("no sidecar sources to bundle");
  let result: Awaited<ReturnType<typeof build>>;
  try {
    result = await build({
      stdin: {
        contents: renderEntry(sources),
        resolveDir: first.root,
        loader: "ts",
        sourcefile: "<katari-sidecar-entry>",
      },
      bundle: true,
      format: "esm",
      platform: "node",
      target: "node20",
      write: false,
      treeShaking: true,
      // esbuild leaves a bundled CommonJS dep's `require(...)` as a shim that throws in ESM. Inject a real
      // `require` via createRequire so a CJS dep (e.g. discord.js) resolves built-ins / CJS at run time.
      banner: {
        js: "import { createRequire as __katariRequire } from 'node:module'; const require = __katariRequire(import.meta.url);",
      },
      plugins: [moduleNamePlugin(sources)],
    });
  } catch (error) {
    throw new BundleError(
      `failed to bundle sidecar: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  const output = result.outputFiles?.[0];
  if (output === undefined)
    throw new BundleError("esbuild produced no output for the sidecar bundle");
  return output.text;
}

/** The synthetic bundle entry: import every package source file (esbuild inlines each, with its package
 *  name set by the plugin below), then hand stdio control to katari-port. */
function renderEntry(sources: PackageSource[]): string {
  const imports = sources
    .flatMap((source) => source.files)
    .map((file) => `import ${JSON.stringify(file)};`)
    .join("\n");
  return `import { __startSidecar } from "@katari-lang/port";\n${imports}\n__startSidecar();\n`;
}

/** Prefix each package source file with the ambient package-name assignment, so a `katari.agent(...)` the
 *  file runs registers under the package name. esbuild evaluates modules in dependency order and keeps each
 *  module's statements contiguous, so the assignment immediately precedes that file's own registrations
 *  even when several packages are bundled together. A file outside every package root (a dependency in
 *  node_modules) is left untouched. */
function moduleNamePlugin(sources: PackageSource[]): Plugin {
  return {
    name: "katari-module-name",
    setup(build) {
      build.onLoad({ filter: /\.(ts|js)$/ }, async (args) => {
        const owner = sources.find((source) => args.path.startsWith(source.root));
        if (owner === undefined) return null; // a dependency — esbuild loads it normally
        const source = await readFile(args.path, "utf8");
        return {
          loader: args.path.endsWith(".ts") ? "ts" : "js",
          contents: `globalThis.__katariModule = ${JSON.stringify(owner.packageName)};\n${source}`,
        };
      });
    },
  };
}

// ─── fs helpers ────────────────────────────────────────────────────────────

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}
