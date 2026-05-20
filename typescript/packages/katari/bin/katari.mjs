#!/usr/bin/env node
// Platform-detection shim. Resolves the prebuilt katari binary shipped
// inside the matching `@katari-lang/cli-<platform>` optionalDependency
// and forwards stdio + arguments + exit code.
//
// PATH enrichment: walks ancestors of the shim file for any
// `node_modules/.bin/` directories and prepends them to PATH before
// spawning the binary. Without this, locally-installed companions
// (`@katari-lang/bundle` -> `katari-bundle` executable) would not be
// findable when the binary is invoked through its absolute path —
// e.g. `./node_modules/.bin/katari apply`, where the shell did not
// already inject the bin dir. (Equivalent to what pnpm / npx do
// transparently, but we always do it.)

import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { delimiter, dirname, resolve } from "node:path";
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

const exe = process.platform === "win32" ? "katari.exe" : "katari";
const pkg = `@katari-lang/cli-${key}/bin/${exe}`;

let binaryPath;
try {
  binaryPath = require.resolve(pkg);
} catch (err) {
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

const env = { ...process.env };
const binDirs = collectBinDirs(fileURLToPath(import.meta.url));
if (binDirs.length > 0) {
  env.PATH = [...binDirs, env.PATH ?? ""].filter(Boolean).join(delimiter);
}

const child = spawn(binaryPath, process.argv.slice(2), {
  stdio: "inherit",
  env,
});

child.on("error", (err) => {
  console.error(`katari: failed to spawn ${binaryPath}: ${err.message}`);
  process.exit(1);
});

child.on("exit", (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 1);
  }
});
