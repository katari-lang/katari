#!/usr/bin/env node
// Cross-check every "version source of truth" in the source tree
// against a release tag. Intended as a precheck job in each release
// workflow so a misaligned tag fails before any artifact is built.
//
// Exit 0  iff every file agrees with the tag.
// Exit 2  with a tabular mismatch report otherwise.
//
// Usage:
//   node scripts/verify-versions.mjs --tag v0.1.0-rc5
//
// Files checked (must stay in sync with `stamp-version.mjs`):
//   - haskell/katari/src/Katari/Version.hs   (katariVersion literal)
//   - haskell/katari/package.yaml            (cabal version, 3-tuple
//                                             prefix only — cabal
//                                             cannot represent -rcN)
//   - typescript/packages/*/package.json     (every workspace pkg)

import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= process.argv.length) {
    console.error(`error: missing --${name} <value>`);
    process.exit(2);
  }
  return process.argv[i + 1];
}

const tag = arg("tag");
const tagMatch = /^v(\d+\.\d+\.\d+)(-[A-Za-z0-9.-]+)?$/.exec(tag);
if (!tagMatch) {
  console.error(`error: --tag must match v<X.Y.Z>[-pre], got '${tag}'`);
  process.exit(2);
}
const expectedFull = tag.slice(1); // "0.1.0-rc5"
const expectedCabalPrefix = tagMatch[1]; // "0.1.0"

const findings = [];

// 1) Katari.Version
{
  const path = resolve(REPO_ROOT, "haskell/katari/src/Katari/Version.hs");
  const src = readFileSync(path, "utf8");
  const m = /katariVersion = "([^"]*)" -- KATARI_VERSION/.exec(src);
  const actual = m ? m[1] : "<sentinel not found>";
  findings.push({
    file: relative(REPO_ROOT, path),
    field: "katariVersion",
    expected: expectedFull,
    actual,
    ok: actual === expectedFull,
  });
}

// 2) cabal (package.yaml) — 3-tuple prefix only
{
  const path = resolve(REPO_ROOT, "haskell/katari/package.yaml");
  const src = readFileSync(path, "utf8");
  const m = /^version:\s*(\d+(?:\.\d+)*)\s*$/m.exec(src);
  const actualPrefix = m ? m[1].split(".").slice(0, 3).join(".") : "<not found>";
  findings.push({
    file: relative(REPO_ROOT, path),
    field: "version (3-tuple prefix)",
    expected: expectedCabalPrefix,
    actual: actualPrefix,
    ok: actualPrefix === expectedCabalPrefix,
  });
}

// 3) TS workspace packages
{
  const root = resolve(REPO_ROOT, "typescript/packages");
  for (const name of readdirSync(root).sort()) {
    const pkgPath = join(root, name, "package.json");
    try {
      statSync(pkgPath);
    } catch {
      continue;
    }
    const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
    findings.push({
      file: relative(REPO_ROOT, pkgPath),
      field: `${pkg.name}.version`,
      expected: expectedFull,
      actual: pkg.version,
      ok: pkg.version === expectedFull,
    });
  }
}

const mismatches = findings.filter((f) => !f.ok);
if (mismatches.length === 0) {
  console.log(`ok: ${findings.length} files all at ${expectedFull}`);
  process.exit(0);
}

console.error(`\nversion mismatch for tag ${tag} (expected ${expectedFull}):\n`);
for (const f of mismatches) {
  console.error(`  - ${f.file}`);
  console.error(`      ${f.field}: expected ${f.expected}, got ${f.actual}`);
}
console.error(
  `\nFix: run 'node scripts/stamp-version.mjs --version ${expectedFull}' and commit, then re-tag.\n`,
);
process.exit(2);
