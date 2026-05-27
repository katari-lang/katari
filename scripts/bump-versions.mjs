#!/usr/bin/env node
// Injects `@katari-lang/cli-<platform>` entries into the `@katari-lang/cli`
// shim's `optionalDependencies`, all pinned to the given release version.
//
// optionalDependencies are intentionally absent from the committed
// source manifest so a pre-first-publish `pnpm install` doesn't fail
// trying to resolve not-yet-on-registry packages. This step runs in
// the release pipeline (`release-npm.yml`) immediately before
// `pnpm publish`.
//
// Note: this script used to also write the `version` field on every
// publishable TS package. That responsibility has moved to
// `scripts/stamp-version.mjs`, which is run by hand before the
// release commit so source = artifact. The release workflow then
// enforces the match via `scripts/verify-versions.mjs`. See
// docs/PUBLISHING.md.
//
// Usage:
//   node scripts/bump-versions.mjs --version 0.1.0

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const PLATFORMS = ["linux-x64", "darwin-arm64"];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= process.argv.length) {
    throw new Error(`missing --${name} <value>`);
  }
  return process.argv[i + 1];
}

const version = arg("version");
const shimPath = resolve(
  REPO_ROOT,
  "typescript/packages/katari/package.json",
);
const pkg = JSON.parse(readFileSync(shimPath, "utf8"));

if (pkg.version !== version) {
  console.error(
    `error: ${shimPath} has version ${pkg.version}, expected ${version}.\n` +
      `       Run 'scripts/verify-versions.mjs --tag v${version}' to see` +
      ` everything that's out of sync, then 'scripts/stamp-version.mjs' to fix.`,
  );
  process.exit(2);
}

pkg.optionalDependencies ??= {};
for (const plat of PLATFORMS) {
  pkg.optionalDependencies[`@katari-lang/cli-${plat}`] = version;
}

writeFileSync(shimPath, `${JSON.stringify(pkg, null, 2)}\n`);
console.log(
  `Injected optionalDependencies into @katari-lang/cli @ ${version} ` +
    `(${PLATFORMS.length} platforms)`,
);
