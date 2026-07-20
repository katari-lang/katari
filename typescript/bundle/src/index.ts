// FFI sidecar bundler. Each input is a `{ packageName, sourceRoot }` pair — one package's sidecar source
// tree. Every sidecar file is equal (each just registers some agents), so there is no privileged entry: the
// bundler generates its own entry that imports every `.ts`/`.js` file under each package's root, and esbuild
// packs them into a single ESM bundle that hands stdio control to `@katari-lang/port` via `__startSidecar()`.
//
// Each source file is prefixed with `globalThis.__katariModule = "<moduleName>"`, where `moduleName` is the
// file's path relative to its package source root with the extension dropped and directory separators as
// dots — exactly how the compiler names a `.ktr` module (`src/foo/bar.ts` → `foo.bar`). So a
// `katari.agent(localName, ...)` the file runs registers under `<moduleName>.<localName>`, the key the
// compiler lowers an `external agent` to. The convention this falls out of: `src/X.ktr` declares the
// external agents, and `src/X.ts` (the same module path) implements them. A plain prepended assignment (not
// a function wrapper) runs before the file body yet keeps its own imports and exports legal at the top level.
//
// Two things the bundler enforces on top of esbuild's resolution, both in `portSingletonPlugin`:
// `@katari-lang/port` is a singleton (it holds process-wide state, so the bundle must contain exactly one
// copy), and that one copy is the bundler's OWN port — the toolchain's, the wire codec that matches the
// runtime this `katari` deploys to — never a package's declared version. The port is the sidecar↔runtime
// wire ABI, so the toolchain owns it: a package pinning an older port can no longer drift its sidecar off
// the runtime's wire format.

import type { Stats } from "node:fs";
import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { dirname, extname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { SidecarBundle } from "@katari-lang/types";
import { build, type Plugin, type ResolveResult } from "esbuild";

export class BundleError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BundleError";
  }
}

export interface BundlePackage {
  /** Package name from `katari.toml` — a label for diagnostics. The registration prefix is the file's
   *  module path (relative to `sourceRoot`), not this, so it matches the compiler's module naming. */
  packageName: string;
  /** Path of the package's sidecar source root. Every `.ts`/`.js` under it is bundled, each registering its
   *  agents under its own module path (the path relative to here, extension dropped, dirs → dots). */
  sourceRoot: string;
}

export interface BundleOptions {
  /** One entry per katari package whose sidecar (if any) should be bundled. */
  packages: BundlePackage[];
  /** Directory the single `@katari-lang/port` resolves from. Defaults to the bundler's own — the
   *  toolchain port that matches the runtime, so a package's declared port never reaches the sidecar.
   *  Only tests set it, inlining a stub port to observe what `__startSidecar()` serves. */
  portResolveDir?: string;
}

/**
 * Bundle every package's sidecar into one ESM bundle, or `null` when no package has a sidecar (the
 * snapshot needs no FFI runtime). Throws `BundleError` on a malformed package layout or an esbuild failure.
 */
export async function bundleSidecar(options: BundleOptions): Promise<SidecarBundle | null> {
  const sources = await resolveSources(options.packages);
  if (sources.length === 0) return null;
  return {
    entry: await runEsbuild(sources, options.portResolveDir ?? bundlerDir),
    runtime: "node",
  };
}

// ─── Source discovery ──────────────────────────────────────────────────────

interface PackageSource {
  /** Absolute source root with a trailing separator, so a prefix test for "is this file in the package"
   *  cannot match a sibling like `<root>-other`, and module paths are taken relative to it. */
  root: string;
  /** Every sidecar source file under `root` (sorted), each imported by the synthetic entry. */
  files: string[];
}

/** Collect every package's sidecar source files, skipping packages with no sidecar source. Sorted by root
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
    sources.push({ root: root + sep, files });
  }
  sources.sort((a, b) => (a.root < b.root ? -1 : 1));
  return sources;
}

/** Every `.ts`/`.js` file under `root` (recursively), sorted for a reproducible bundle. Symlinks are
 *  followed (a symlinked source file or directory is included, like the compiler's `.ktr` scan), guarding
 *  against cycles by walking each canonical directory once. Type-declaration files (`.d.ts`) are skipped —
 *  they carry no runtime code to register. */
async function collectSourceFiles(root: string): Promise<string[]> {
  const files: string[] = [];
  const seenDirectories = new Set<string>();
  const directories = [root];
  for (let directory = directories.pop(); directory !== undefined; directory = directories.pop()) {
    // A directory reached twice (a symlink loop, or a shared symlinked subtree) is walked once. Keying on
    // the canonical path is what makes the guard cycle-proof.
    const canonical = await realpath(directory);
    if (seenDirectories.has(canonical)) continue;
    seenDirectories.add(canonical);
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const full = join(directory, entry.name);
      // Classify by the symlink's target (the `Dirent` reflects the link itself), so a symlinked source is
      // followed rather than skipped; a broken symlink resolves to null and is ignored.
      const target = entry.isSymbolicLink() ? await statOrNull(full) : entry;
      if (target === null) continue;
      if (target.isDirectory()) directories.push(full);
      else if (target.isFile() && isSourceFile(entry.name)) files.push(full);
    }
  }
  return files.sort();
}

async function statOrNull(path: string): Promise<Stats | null> {
  try {
    return await stat(path);
  } catch {
    return null;
  }
}

function isSourceFile(name: string): boolean {
  if (name.endsWith(".d.ts")) return false; // a type-declaration file, not a runtime module
  return extname(name) === ".ts" || extname(name) === ".js";
}

// ─── esbuild ─────────────────────────────────────────────────────────────

async function runEsbuild(sources: PackageSource[], portResolveDir: string): Promise<string> {
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
      plugins: [portSingletonPlugin(portResolveDir), moduleNamePlugin(sources)],
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

/** The bare specifier of the port library — the sidecar protocol runtime every handler file imports. */
const portSpecifier = "@katari-lang/port";

/** Marker `pluginData` for the plugin's own canonical resolution, so it passes through instead of
 *  re-entering the hook (which would recurse forever). */
const portCanonicalResolution = "katari-port-canonical";

/** The bundler's own directory. Every sidecar resolves the port from here, so the copy that lands in the
 *  bundle is the toolchain's — the one `@katari-lang/bundle` depends on — not one a package carries. */
const bundlerDir = dirname(fileURLToPath(import.meta.url));

/** Pin every import of `@katari-lang/port` to one module: the bundler's own. The port holds process-wide
 *  state — the handler registry `katari.agent(...)` writes into and `__startSidecar()` serves, and
 *  ownership of stdio — so the bundle must contain exactly one copy. Resolving it from the bundler rather
 *  than the importing package serves two ends at once. It is a singleton: without pinning, each vendored
 *  package resolves the port from its own `node_modules`, esbuild inlines one registry per package, and
 *  only the entry's copy is served — every other package's handlers register into a registry nothing
 *  reads. And it is the *toolchain's* port: the wire codec that matches the runtime this `katari` deploys
 *  to. The port is the sidecar↔runtime ABI, so the toolchain owns it — a package declaring an older port
 *  can no longer drift its sidecar off the runtime's wire format. */
function portSingletonPlugin(portResolveDir: string): Plugin {
  return {
    name: "katari-port-singleton",
    setup(build) {
      let canonical: Promise<ResolveResult> | undefined;
      build.onResolve({ filter: /^@katari-lang\/port$/ }, (args) => {
        if (args.pluginData === portCanonicalResolution) return null; // our own probe — resolve normally
        canonical ??= build.resolve(portSpecifier, {
          // One resolution for every importer — the toolchain's port (`portResolveDir` defaults to the
          // bundler's own), never the importing package's, so the sidecar always speaks the runtime's wire.
          resolveDir: portResolveDir,
          kind: "import-statement",
          pluginData: portCanonicalResolution,
        });
        return canonical.then((resolved) =>
          resolved.errors.length > 0 ? { errors: resolved.errors } : { path: resolved.path },
        );
      });
    },
  };
}

/** Prefix each package source file with its module-name assignment, so a `katari.agent(...)` the file runs
 *  registers under `<moduleName>.<name>`. esbuild evaluates modules in dependency order and keeps each
 *  module's statements contiguous, so the assignment immediately precedes that file's own registrations
 *  even when several files are bundled together. A file outside every package root (a dependency in
 *  node_modules) is left untouched. */
function moduleNamePlugin(sources: PackageSource[]): Plugin {
  return {
    name: "katari-module-name",
    setup(build) {
      build.onLoad({ filter: /\.(ts|js)$/ }, async (args) => {
        const owner = sources.find((source) => args.path.startsWith(source.root));
        if (owner === undefined) return null; // a dependency — esbuild loads it normally
        const source = await readFile(args.path, "utf8");
        const moduleName = moduleNameOf(args.path, owner.root);
        return {
          loader: args.path.endsWith(".ts") ? "ts" : "js",
          contents: `globalThis.__katariModule = ${JSON.stringify(moduleName)};\n${source}`,
        };
      });
    },
  };
}

/** A source file's module name: its path relative to the package source root, extension dropped, directory
 *  separators turned into dots — the same naming the compiler gives a `.ktr` module. */
function moduleNameOf(file: string, root: string): string {
  return relative(root, file)
    .replace(/\.(ts|js)$/, "")
    .split(sep)
    .join(".");
}

// ─── fs helpers ────────────────────────────────────────────────────────────

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await stat(path)).isDirectory();
  } catch {
    return false;
  }
}
