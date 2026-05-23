#!/usr/bin/env node
// `katari-bundle` — CLI front for `bundleSidecar`.
//
// Reads packages from `--package <name>=<path>` args (one or more) and
// writes a JSON document to stdout containing either:
//
//   { "bundle": SidecarBundle, "modules": string[] }
//
// when at least one package contributes a sidecar `.ts` / `.js` file,
// or
//
//   { "bundle": null, "modules": [] }
//
// when no sidecars are present (the runtime then runs without a
// sidecar). The exit code is 0 on success; 1 means a bundle failure
// surfaced from esbuild.
//
// The Haskell `katari apply` spawns this binary with stdio piped so
// the produced bundle bytes never round-trip through the filesystem.

import { bundleSidecar, BundleError, type BundlePackage } from "./index.js";

interface ParsedArgs {
  packages: BundlePackage[];
}

function parseArgs(argv: string[]): ParsedArgs {
  // No-args → print help and exit 0 so users get a usage hint when they
  // run the binary directly.
  if (argv.length === 0) {
    printHelp(process.stdout);
    process.exit(0);
  }
  const packages: BundlePackage[] = [];
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "--package") {
      const v = argv[i + 1];
      if (v === undefined) {
        bail("--package requires a value of the form <name>=<path>");
      }
      const eq = v.indexOf("=");
      if (eq === -1 || eq === 0 || eq === v.length - 1) {
        bail(`--package value must be of the form <name>=<path> (got '${v}')`);
      }
      packages.push({
        packageName: v.slice(0, eq),
        sourceRoot: v.slice(eq + 1),
      });
      i += 2;
      continue;
    }
    if (a === "--help" || a === "-h") {
      printHelp(process.stdout);
      process.exit(0);
    }
    bail(`unknown argument: ${a}`);
  }
  if (packages.length === 0) {
    bail("at least one --package is required");
  }
  return { packages };
}

function printHelp(out: NodeJS.WritableStream): void {
  out.write(
    [
      "Usage: katari-bundle --package <name>=<path> [--package <name>=<path> ...]",
      "",
      "Walks each package's source root for a single .ts/.js sidecar file,",
      "bundles them into an ESM bundle, and writes { bundle, modules } JSON to",
      "stdout. Each package contributes at most one sidecar; agent registrations",
      "live under <packageName>.<localName> in the bundle's registry.",
      "",
      "Exit codes:",
      "  0  success (= valid JSON written to stdout)",
      "  1  bundle failure surfaced from esbuild",
      "  2  argument / usage error",
      "",
    ].join("\n"),
  );
}

function bail(msg: string, code = 2): never {
  process.stderr.write(`katari-bundle: ${msg}\n`);
  process.exit(code);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  try {
    const result = await bundleSidecar({ packages: args.packages });
    if (result === null) {
      process.stdout.write(JSON.stringify({ bundle: null, modules: [] }) + "\n");
    } else {
      process.stdout.write(
        JSON.stringify({ bundle: result.bundle, modules: result.modules }) + "\n",
      );
    }
  } catch (err) {
    // BundleError = bundling pipeline rejected the input (esbuild
    // failure / per-package sidecar conflict / etc.). Exit 1 so callers
    // can distinguish from usage errors (exit 2).
    if (err instanceof BundleError) {
      bail(err.message, 1);
    }
    bail(err instanceof Error ? err.message : String(err), 1);
  }
}

await main();
