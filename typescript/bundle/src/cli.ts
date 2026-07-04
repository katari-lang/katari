#!/usr/bin/env node
// `katari-bundle` — the CLI front for `bundleSidecar`. Reads one or more `--package <name>=<path>` flags
// and writes `{ "bundle": SidecarBundle | null }` JSON to stdout: the compiled sidecar, or null when no
// package has a sidecar (the snapshot then runs without one). The Haskell `katari apply` spawns this with
// stdio piped, so the bundle bytes never round-trip through the filesystem.
//
// Exit codes: 0 success (valid JSON on stdout) · 1 bundle failure · 2 usage error.

import { type BundlePackage, bundleSidecar } from "./index.js";

function parsePackages(argv: string[]): BundlePackage[] {
  if (argv.length === 0 || argv.includes("--help") || argv.includes("-h")) {
    printHelp();
    process.exit(0);
  }
  const packages: BundlePackage[] = [];
  for (let i = 0; i < argv.length; i += 2) {
    if (argv[i] !== "--package") bail(`unknown argument: ${argv[i]}`);
    const value = argv[i + 1];
    if (value === undefined) bail("--package requires a value of the form <name>=<path>");
    const eq = value.indexOf("=");
    if (eq <= 0 || eq === value.length - 1) {
      bail(`--package value must be of the form <name>=<path> (got '${value}')`);
    }
    packages.push({ packageName: value.slice(0, eq), sourceRoot: value.slice(eq + 1) });
  }
  if (packages.length === 0) bail("at least one --package is required");
  return packages;
}

function printHelp(): void {
  process.stdout.write(
    [
      "Usage: katari-bundle --package <name>=<path> [--package <name>=<path> ...]",
      "",
      "Bundles each package's FFI sidecar (the `<name>.ts` entry under <path>, plus the files it",
      "imports) into one ESM bundle and writes { bundle } JSON to stdout. Agent registrations live",
      "under <name>.<localName>. Writes { bundle: null } when no package has a sidecar.",
      "",
      "Exit codes: 0 success · 1 bundle failure · 2 usage error",
      "",
    ].join("\n"),
  );
}

function bail(message: string, code = 2): never {
  process.stderr.write(`katari-bundle: ${message}\n`);
  process.exit(code);
}

async function main(): Promise<void> {
  const packages = parsePackages(process.argv.slice(2));
  try {
    const bundle = await bundleSidecar({ packages });
    process.stdout.write(`${JSON.stringify({ bundle })}\n`);
  } catch (error) {
    // A bundling failure (bad package layout / esbuild error) → exit 1, distinct from the exit-2 usage
    // errors above so callers can tell "katari is mis-invoked" from "the sidecar source is broken".
    bail(error instanceof Error ? error.message : String(error), 1);
  }
}

await main();
