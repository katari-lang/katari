// Release precheck: cross-check every version source of truth against a pushed git tag. Every
// release workflow runs this before building or publishing anything, so a half-stamped tree can
// never ship under a tag it does not match.
//
//   node scripts/verify-versions.mjs --tag v0.1.0-rc7
//
// Checks (the same set stamp-version.mjs writes):
//   - haskell/cli/VERSION == the tag's version, exactly.
//   - haskell/*/package.yaml `version:` == the tag's X.Y.Z release triple (+ .0).
//   - typescript/*/package.json `version` == the tag's version, exactly.

import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { parseTagArgument, repoRoot, typescriptPackageDirs } from "./versions-common.mjs";

const version = parseTagArgument(process.argv, "verify-versions");
const release = version.split("-")[0];

const mismatches = [];
function check(label, actual, expected) {
  if (actual !== expected) mismatches.push({ label, actual, expected });
}

check(
  "haskell/cli/VERSION",
  readFileSync(join(repoRoot, "haskell/cli/VERSION"), "utf8").trim(),
  version,
);

for (const name of readdirSync(join(repoRoot, "haskell"))) {
  const packageYaml = join(repoRoot, "haskell", name, "package.yaml");
  let source;
  try {
    source = readFileSync(packageYaml, "utf8");
  } catch {
    continue;
  }
  const found = source.match(/^version: (.*)$/m);
  check(`haskell/${name}/package.yaml`, found?.[1], `${release}.0`);
}

for (const dir of typescriptPackageDirs()) {
  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  check(`${relative(repoRoot, dir)}/package.json`, manifest.version, version);
}

if (mismatches.length > 0) {
  console.error(`verify-versions: tree does not match tag v${version}:`);
  for (const { label, actual, expected } of mismatches) {
    console.error(`  ${label}: ${actual} (expected ${expected})`);
  }
  console.error(`fix with: node scripts/stamp-version.mjs --version ${version}`);
  process.exit(2);
}
console.log(`verify-versions: all sources match v${version}`);
