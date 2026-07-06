#!/usr/bin/env node
// Platform-detection shim. Resolves the prebuilt katari binary shipped
// inside the matching `@katari-lang/cli-<platform>` optionalDependency
// and forwards stdio + arguments + exit code.
//
// Bundle wiring: the Haskell binary resolves `katari-bundle` in this
// order — KATARI_BUNDLE_BIN, then `node_modules/.bin/katari-bundle`
// walking up from the project directory, then PATH. When the user runs
// through this shim we know exactly where @katari-lang/bundle lives
// (it is our optionalDependency), so we export KATARI_BUNDLE_BIN
// directly instead of hoping the project-local walk or PATH finds it.
//
// PATH enrichment: walks ancestors of the shim file for any
// `node_modules/.bin/` directories and prepends them to PATH before
// spawning the binary. This keeps other locally-installed companions
// findable when the binary is invoked through its absolute path —
// e.g. `./node_modules/.bin/katari apply`, where the shell did not
// already inject the bin dir. (Equivalent to what pnpm / npx do
// transparently, but we always do it.)

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);

const supported = new Set([
  "linux-x64",
  "darwin-arm64",
]);

const key = `${process.platform}-${process.arch}`;

if (!supported.has(key)) {
  console.error(
    `katari: no prebuilt binary for ${key}.\n` +
      `Supported platforms: ${[...supported].join(", ")}.\n` +
      `See https://github.com/katari-lang/katari/releases for tarball downloads,\n` +
      `or build from source with stack.`,
  );
  process.exit(1);
}

const pkg = `@katari-lang/cli-${key}/bin/katari`;

let binaryPath;
try {
  binaryPath = require.resolve(pkg);
} catch {
  console.error(
    `katari: failed to locate ${pkg}.\n` +
      `The matching @katari-lang/cli-${key} package was not installed — this\n` +
      `usually means npm/pnpm skipped the optionalDependency. Try reinstalling:\n` +
      `  npm i -g @katari-lang/cli\n` +
      `If the problem persists, file an issue with your npm/pnpm version.`,
  );
  process.exit(1);
}

function collectBinDirs(startFile) {
  const dirs = [];
  const seen = new Set();
  let cur = dirname(startFile);
  while (true) {
    const candidate = resolve(cur, "node_modules", ".bin");
    if (!seen.has(candidate) && existsSync(candidate)) {
      dirs.push(candidate);
      seen.add(candidate);
    }
    const parent = dirname(cur);
    if (parent === cur) break;
    cur = parent;
  }
  return dirs;
}

// @katari-lang/bundle is a regular dependency of this package, so `apply`
// always has a bundler. Point KATARI_BUNDLE_BIN at its CLI entry (next to the
// resolved module inside dist/) so the katari binary uses this exact copy —
// this is what makes a global install work, where the project directory has no
// local node_modules/.bin/katari-bundle to walk to. If resolution somehow
// fails, the katari binary resolves the bundler itself and owns the precise
// "bundler not found" error, so we do not second-guess it here.
let bundleBin = null;
try {
  bundleBin = join(dirname(require.resolve("@katari-lang/bundle")), "cli.mjs");
} catch {
  // Unresolvable (a broken install); leave it to the katari binary.
}

const env = { ...process.env };
const binDirs = collectBinDirs(fileURLToPath(import.meta.url));
if (binDirs.length > 0) {
  env.PATH = [...binDirs, env.PATH ?? ""].filter(Boolean).join(delimiter);
}
if (bundleBin !== null && env.KATARI_BUNDLE_BIN === undefined) {
  env.KATARI_BUNDLE_BIN = bundleBin;
}

const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  env,
});

child.on("error", (err) => {
  console.error(`katari: failed to spawn ${binaryPath}: ${err.message}`);
  process.exit(1);
});

// Use `close` rather than `exit` so we wait until the child's stdio
// streams drain before mirroring its exit code. With "inherit" stdio
// the parent shares fds so the distinction rarely matters, but `close`
// is the correct event when output ordering matters.
child.on("close", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 1);
  }
});
