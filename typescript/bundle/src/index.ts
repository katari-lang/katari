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
//
// A third is containment, enforced in two places because a package in the dependency closure may have been
// fetched from a registry and must not be trusted with the build machine's filesystem: `collectSourceFiles`
// keeps only files whose real path stays under the package's source root, and `importAllowlistPlugin`
// rejects any import that resolves outside the package sources, their installed dependencies and the
// toolchain's own port. Both compare canonical paths, since a symlink is only as contained as its target.

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
  /** Package name from `katari.toml`, carried this far only so a containment rejection can say which
   *  package's sidecar wrote the offending import. */
  packageName: string;
  /** Absolute, canonical source root. Membership tests against it go through `isUnder`, which compares
   *  whole path segments so a sibling like `<root>-other` cannot pass for a file in the package. */
  root: string;
  /** Every sidecar source file under `root` (canonical and sorted), each imported by the synthetic entry. */
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
    sources.push({ packageName: pkg.packageName, root, files });
  }
  sources.sort((a, b) => (a.root < b.root ? -1 : 1));
  return sources;
}

/** Every `.ts`/`.js` file under `root` (recursively), canonicalized and sorted for a reproducible bundle.
 *  Symlinks are followed (a symlinked source file or directory is included, like the compiler's `.ktr`
 *  scan), guarding against cycles by walking each canonical directory once.
 *
 *  A directory or file is kept only when its *canonical* path stays strictly under `root`, which is what
 *  keeps the caller from being the only thing standing between an untrusted package and the rest of the
 *  disk: a `src/` containing a symlink to `/etc` or to a sibling checkout pulls in nothing. The root itself
 *  is walked unconditionally — it is the thing being scanned, and it was canonicalized before we got here.
 *  This mirrors `collectKtrFiles` in `Katari.Project.Discovery` exactly, so the compiler's view of what
 *  belongs to a package and the bundler's cannot drift apart.
 *
 *  Type-declaration files (`.d.ts`) are skipped — they carry no runtime code to register. */
async function collectSourceFiles(root: string): Promise<string[]> {
  const files = new Set<string>();
  const seenDirectories = new Set<string>([root]);
  const directories = [root];
  for (let directory = directories.pop(); directory !== undefined; directory = directories.pop()) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const full = join(directory, entry.name);
      // Classify by the symlink's target (the `Dirent` reflects the link itself), so a symlinked source is
      // followed rather than skipped; a broken symlink resolves to null and is ignored.
      const target = entry.isSymbolicLink() ? await statOrNull(full) : entry;
      if (target === null) continue;
      if (!target.isDirectory() && !(target.isFile() && isSourceFile(entry.name))) continue;
      const canonical = await realpathOrNull(full);
      if (canonical === null || !isUnder(root, canonical)) continue; // a symlink out of the tree
      if (target.isFile()) {
        files.add(canonical);
        continue;
      }
      // A directory reached twice (a symlink loop, or a shared symlinked subtree) is walked once. Keying
      // on the canonical path is what makes the guard cycle-proof, and walking the canonical path keeps
      // every descendant's containment check honest.
      if (seenDirectories.has(canonical)) continue;
      seenDirectories.add(canonical);
      directories.push(canonical);
    }
  }
  return [...files].sort();
}

/** Is `path` strictly inside `root`? Whole path segments are compared, so a sibling named `<root>-other`
 *  is not "inside" `<root>`, and a path equal to the root does not count as under it — the same `isUnder`
 *  the compiler's `.ktr` scan applies. */
function isUnder(root: string, path: string): boolean {
  const prefix = root.endsWith(sep) ? root : root + sep;
  return path.startsWith(prefix);
}

async function statOrNull(path: string): Promise<Stats | null> {
  try {
    return await stat(path);
  } catch {
    return null;
  }
}

async function realpathOrNull(path: string): Promise<string | null> {
  try {
    return await realpath(path);
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
  // The port pin seeds this with the toolchain's own port, and the allowlist grows it with everything the
  // port imports; see `importAllowlistPlugin` for why that trust has to propagate.
  const toolchainModules = new Set<string>();
  const rejectedImports: string[] = [];
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
      // The port pin runs first so `@katari-lang/port` never reaches the allowlist: the bundler resolves
      // that one itself, from a directory it chose, and the allowlist has no package to attribute it to.
      plugins: [
        portSingletonPlugin(portResolveDir, toolchainModules),
        importAllowlistPlugin(sources, toolchainModules, rejectedImports),
        moduleNamePlugin(sources),
      ],
    });
  } catch (error) {
    // A containment rejection already names the import, its importer and what it would have read, which
    // says far more than esbuild's "Build failed with 1 error" wrapper around the same text.
    const [rejected] = rejectedImports;
    if (rejected !== undefined) throw new BundleError(rejected);
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
function portSingletonPlugin(portResolveDir: string, toolchainModules: Set<string>): Plugin {
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
        return canonical.then((resolved) => {
          if (resolved.errors.length > 0) return { errors: resolved.errors };
          // Seed the allowlist's notion of toolchain code with the port the bundler just chose for itself.
          toolchainModules.add(resolved.path);
          return { path: resolved.path };
        });
      });
    },
  };
}

/** Marker `pluginData` for the allowlist's own resolution probe, so the re-entrant `build.resolve` below
 *  falls through to esbuild instead of probing (and so recursing) forever. */
const importAllowlistProbe = "katari-import-allowlist-probe";

/**
 * Reject any import that resolves to a file the sidecar has no business reading.
 *
 * esbuild resolves an absolute-path import as a plain file path, and its default loaders cover `.json` and
 * `.txt`. Without this, a sidecar source could write `import secret from "/home/me/.aws/credentials.json"`
 * and have that file INLINED into the bundle at build time — on the developer's or CI machine — then read
 * back by the package's own handler once the sidecar runs on the runtime. Every package in the resolved
 * dependency closure is bundled, including ones fetched from a registry, so build-host files must be out
 * of reach of all of them.
 *
 * Four things may be imported, and the second is where the obvious rule goes wrong:
 *
 *   - Anything under a package's source root: its own sidecar files and their relative imports.
 *   - Anything under one of the `node_modules` directories Node itself would search from a package's
 *     source root, that is `<ancestor>/node_modules` for every ancestor. "Must be under the package
 *     directory" is NOT the rule and would break real builds: pnpm links `<package>/node_modules/discord.js`
 *     into a virtual store, so the dependency's real path is `<store>/.pnpm/discord.js@14/node_modules/…`,
 *     and that store lives in the `node_modules` of the workspace (or project) root — an ancestor of the
 *     package, not the package itself. Taking the whole ancestor search path covers the isolated layout and
 *     the workspace layout alike, and still admits nothing that is not inside an installed dependency tree.
 *   - Anything the toolchain's own `@katari-lang/port` pulls in, tracked transitively as the build runs. A
 *     published install has the port under a `node_modules` the rule above already covers, but a source
 *     checkout has pnpm link it straight to a sibling workspace directory that no `node_modules` contains.
 *     The port is resolved by the bundler, from a directory the bundler chose, so what it imports is
 *     toolchain code too — trust propagates from it rather than being guessed from a path shape.
 *   - Node built-ins (`node:fs`, `fs`, …), which stay external under `platform: "node"`: nothing is read
 *     from disk, so there is nothing to contain, and sidecars legitimately use them.
 */
function importAllowlistPlugin(
  sources: PackageSource[],
  toolchainModules: Set<string>,
  rejectedImports: string[],
): Plugin {
  const allowedRoots = sources.flatMap((source) => [
    source.root,
    ...nodeModulesSearchPath(source.root),
  ]);
  return {
    name: "katari-import-allowlist",
    setup(build) {
      build.onResolve({ filter: /.*/ }, async (args) => {
        if (args.pluginData === importAllowlistProbe) return null; // our own probe — resolve normally
        // The port pin's probe reaches this hook too, because that plugin returns null to let esbuild
        // resolve its one canonical port. That is the bundler resolving its own toolchain rather than a
        // package's import, and probing it here would deadlock on the pin's still-pending promise.
        if (args.pluginData === portCanonicalResolution) return null;
        // Probe where the import would land, then return null so esbuild performs the real resolution
        // itself. This hook can therefore only reject an import, never reshape one that is allowed.
        const resolved = await build.resolve(args.path, {
          importer: args.importer,
          namespace: args.namespace,
          resolveDir: args.resolveDir,
          kind: args.kind,
          with: args.with,
          pluginData: importAllowlistProbe,
        });
        if (resolved.errors.length > 0) return null; // let esbuild report its own "could not resolve"
        if (resolved.external) return null; // a node built-in or other external — no file is read
        if (resolved.namespace !== "file") return null; // a virtual module, not a path on disk
        if (toolchainModules.has(args.importer)) {
          toolchainModules.add(resolved.path);
          return null;
        }
        // Compare canonical paths: a symlink is only as contained as whatever it points at.
        const canonical = (await realpathOrNull(resolved.path)) ?? resolved.path;
        if (allowedRoots.some((root) => isUnder(root, canonical))) return null;
        const message = describeRejectedImport(sources, args.path, args.importer, canonical);
        rejectedImports.push(message);
        return { errors: [{ text: message }] };
      });
    },
  };
}

/** Every `<ancestor>/node_modules` from `directory` up to the filesystem root — exactly the directories
 *  Node's resolver searches for a bare specifier imported from `directory`, and so exactly the installed
 *  dependency trees a package may legitimately reach, pnpm's `node_modules/.pnpm` store included. */
function nodeModulesSearchPath(directory: string): string[] {
  const paths: string[] = [];
  for (let current = directory; ; current = dirname(current)) {
    paths.push(join(current, "node_modules"));
    if (dirname(current) === current) return paths;
  }
}

/** Spell out which import was rejected, who wrote it and what it would have read. A user who trips this
 *  legitimately — a source file kept outside the declared source root, say — otherwise has only esbuild's
 *  resolved path to go on and no way to tell a mislaid file from a hostile one. */
function describeRejectedImport(
  sources: PackageSource[],
  specifier: string,
  importer: string,
  canonical: string,
): string {
  const owner = sources.find((source) => isUnder(source.root, importer));
  const origin =
    owner === undefined
      ? `${importer} (a bundled dependency)`
      : `${importer} (package '${owner.packageName}')`;
  return [
    `refusing to bundle ${JSON.stringify(specifier)} imported by ${origin}:`,
    `it resolves to ${canonical}, outside the package's sidecar sources and its installed dependencies.`,
    "A sidecar may import its own source files, its package's npm dependencies and node built-ins;",
    "reading other files from the build machine is not allowed.",
  ].join(" ");
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
        const owner = sources.find((source) => isUnder(source.root, args.path));
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
