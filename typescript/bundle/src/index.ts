// FFI sidecar bundler. Each input is a `{ packageName, sourceRoot }` pair — one package's sidecar source
// tree. A package's sidecar is the entry `<packageName>.ts` (or `.js`), or the sole top-level file when
// there is only one; esbuild follows its imports and packs them into a single ESM bundle. The bundle hands
// stdio control to `@katari-lang/port` via `__startSidecar()`.
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
  const roots = await resolveEntries(options.packages);
  if (roots.length === 0) return null;
  return { entry: await runEsbuild(roots), runtime: "node" };
}

// ─── Entry discovery ───────────────────────────────────────────────────────

interface PackageRoot {
  packageName: string;
  /** Absolute source root with a trailing separator, so a prefix test for "is this file in the package"
   *  cannot match a sibling like `<root>-other`. */
  root: string;
  /** Absolute path of the sidecar entry esbuild bundles from. */
  entryPath: string;
}

/** Resolve each package's sidecar entry, skipping packages with no sidecar source. Sorted by name for a
 *  reproducible bundle. */
async function resolveEntries(packages: BundlePackage[]): Promise<PackageRoot[]> {
  const roots: PackageRoot[] = [];
  for (const pkg of packages) {
    const resolved = resolve(pkg.sourceRoot);
    if (!(await isDirectory(resolved))) continue; // the package has no sidecar source at all
    // Canonicalize symlinks (e.g. macOS `/var` → `/private/var`) so the plugin's "is this file inside the
    // package" prefix test matches esbuild's own realpath'd `args.path`.
    const root = await realpath(resolved);
    const entryPath = await findEntry(root, pkg.packageName);
    if (entryPath === null) continue; // a source dir with no .ts/.js sidecar — nothing to bundle
    roots.push({ packageName: pkg.packageName, root: root + sep, entryPath });
  }
  roots.sort((a, b) => (a.packageName < b.packageName ? -1 : 1));
  return roots;
}

/** The sidecar entry under `root`: the package-named file `<packageName>.{ts,js}`, or — when the sidecar
 *  is a single file — the sole top-level `.ts`/`.js`. `null` when the root holds no sidecar source; throws
 *  when it holds several top-level files but none names the entry. Helper files live in subdirectories
 *  (esbuild follows the entry's imports), so only the top level is scanned for the entry. */
async function findEntry(root: string, packageName: string): Promise<string | null> {
  const named = await firstExisting([
    join(root, `${packageName}.ts`),
    join(root, `${packageName}.js`),
  ]);
  if (named !== null) return named;

  const topLevel = (await readdir(root, { withFileTypes: true }))
    .filter(
      (entry) => entry.isFile() && (extname(entry.name) === ".ts" || extname(entry.name) === ".js"),
    )
    .map((entry) => join(root, entry.name));
  if (topLevel.length === 0) return null;
  const [only] = topLevel;
  if (only !== undefined && topLevel.length === 1) return only;
  throw new BundleError(
    `package "${packageName}" has ${topLevel.length} top-level sidecar files but none named ` +
      `"${packageName}.ts" to serve as the entry:\n  - ${topLevel.join("\n  - ")}\n` +
      `Name the entry "${packageName}.ts" and import the others from it (they bundle together).`,
  );
}

// ─── esbuild ─────────────────────────────────────────────────────────────

async function runEsbuild(roots: PackageRoot[]): Promise<string> {
  // The caller only reaches here with at least one root; resolve the synthetic entry's relative imports
  // against the first package's directory.
  const [first] = roots;
  if (first === undefined) throw new BundleError("no sidecar entries to bundle");
  let result: Awaited<ReturnType<typeof build>>;
  try {
    result = await build({
      stdin: {
        contents: renderEntry(roots),
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
      plugins: [moduleNamePlugin(roots)],
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

/** The synthetic bundle entry: import each package entry (esbuild inlines its body, with the package name
 *  set by the plugin below), then hand stdio control to katari-port. */
function renderEntry(roots: PackageRoot[]): string {
  const imports = roots.map((root) => `import ${JSON.stringify(root.entryPath)};`).join("\n");
  return `import { __startSidecar } from "@katari-lang/port";\n${imports}\n__startSidecar();\n`;
}

/** Prefix each package source file with the ambient package-name assignment, so a `katari.agent(...)` the
 *  file runs registers under the package name. esbuild evaluates modules in dependency order and keeps each
 *  module's statements contiguous, so the assignment immediately precedes that file's own registrations
 *  even when several packages are bundled together. A file outside every package root (a dependency in
 *  node_modules) is left untouched. */
function moduleNamePlugin(roots: PackageRoot[]): Plugin {
  return {
    name: "katari-module-name",
    setup(build) {
      build.onLoad({ filter: /\.(ts|js)$/ }, async (args) => {
        const owner = roots.find((root) => args.path.startsWith(root.root));
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

async function firstExisting(paths: string[]): Promise<string | null> {
  for (const path of paths) {
    if (await isFile(path)) return path;
  }
  return null;
}

async function isFile(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isFile();
  } catch {
    return false;
  }
}
