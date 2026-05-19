#!/usr/bin/env node
// `katari-bundle` — CLI front for `bundleSidecar`.
//
// Reads source roots from --source-root <path> args (one or more) and
// writes a JSON document to stdout containing either:
//
//   { "bundle": SidecarBundle, "modules": string[] }
//
// when at least one .ktr file with a .ts/.js sibling is found, or
//
//   { "bundle": null, "modules": [] }
//
// when no sidecars are present (the runtime then runs without a
// sidecar). The exit code is 0 on success; 1 means a bundle failure
// surfaced from esbuild.
//
// The Haskell `katari apply` spawns this binary with stdio piped so
// the produced bundle bytes never round-trip through the filesystem.

import { bundleSidecar, BundleError } from "./index.js";

interface ParsedArgs {
  sourceRoots: string[];
}

function parseArgs(argv: string[]): ParsedArgs {
  const sourceRoots: string[] = [];
  let i = 0;
  while (i < argv.length) {
    const a = argv[i];
    if (a === "--source-root") {
      const v = argv[i + 1];
      if (v === undefined) {
        bail(`--source-root requires a value`);
      }
      sourceRoots.push(v);
      i += 2;
      continue;
    }
    if (a === "--help" || a === "-h") {
      printHelp();
      process.exit(0);
    }
    bail(`unknown argument: ${a}`);
  }
  if (sourceRoots.length === 0) {
    bail("at least one --source-root is required");
  }
  return { sourceRoots };
}

function printHelp(): void {
  process.stdout.write(
    [
      "Usage: katari-bundle --source-root <PATH> [--source-root <PATH> ...]",
      "",
      "Walks each source root for .ktr files with sibling .ts/.js, bundles them into",
      "an ESM bundle, and writes { bundle, modules } JSON to stdout.",
      "",
    ].join("\n"),
  );
}

function bail(msg: string): never {
  process.stderr.write(`katari-bundle: ${msg}\n`);
  process.exit(2);
}

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  try {
    const result = await bundleSidecar({ sourceRoots: args.sourceRoots });
    if (result === null) {
      process.stdout.write(JSON.stringify({ bundle: null, modules: [] }) + "\n");
    } else {
      process.stdout.write(
        JSON.stringify({ bundle: result.bundle, modules: result.modules }) + "\n",
      );
    }
  } catch (err) {
    if (err instanceof BundleError) {
      bail(err.message);
    }
    bail(err instanceof Error ? err.message : String(err));
  }
}

await main();
