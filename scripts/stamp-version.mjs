#!/usr/bin/env node
// Rewrite every "version source of truth" in the source tree to match
// the given version string. Run this by hand (or via a release branch
// bot) before tagging:
//
//   node scripts/stamp-version.mjs --version 0.1.0-rc5
//   git commit -am "release: 0.1.0-rc5"
//   git tag v0.1.0-rc5
//
// Sources touched:
//   - haskell/katari/src/Katari/Version.hs   (katariVersion literal,
//                                             matched via the
//                                             "-- KATARI_VERSION"
//                                             sentinel)
//   - haskell/katari/package.yaml            (cabal version; 3-tuple
//                                             prefix only — the 4th
//                                             component is forced to 0
//                                             since cabal cannot
//                                             represent a -rcN suffix)
//   - typescript/packages/*/package.json     (every workspace pkg)
//
// `verify-versions.mjs` reads the same set and errors out if any
// disagree with the pushed git tag. The CLI shim's
// `optionalDependencies` for `@katari-lang/cli-<platform>` is NOT
// touched here — that's still injected by the release pipeline
// (`bump-versions.mjs`) so the source tree's lockfile stays installable
// before the first publish.

import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
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

const version = arg("version");
const m = /^(\d+\.\d+\.\d+)(-[A-Za-z0-9.-]+)?$/.exec(version);
if (!m) {
  console.error(`error: --version must match <X.Y.Z>[-pre], got '${version}'`);
  process.exit(2);
}
const cabalVersion = `${m[1]}.0`;

stampVersionHs(version);
stampCabal(cabalVersion);
const tsFiles = [];
for (const pkgPath of tsPackageJsons()) {
  stampPackageJson(pkgPath, version);
  tsFiles.push(pkgPath);
}

console.log(`Stamped katari version to ${version} (cabal: ${cabalVersion})`);
console.log(`  - haskell/katari/src/Katari/Version.hs`);
console.log(`  - haskell/katari/package.yaml`);
for (const p of tsFiles) {
  console.log(`  - ${p.replace(`${REPO_ROOT}/`, "")}`);
}

function stampVersionHs(version) {
  const path = resolve(REPO_ROOT, "haskell/katari/src/Katari/Version.hs");
  const src = readFileSync(path, "utf8");
  const re =
    /(katariVersion :: String\nkatariVersion = )"[^"]*"( -- KATARI_VERSION)/;
  if (!re.test(src)) {
    console.error(`error: KATARI_VERSION sentinel not found in ${path}`);
    process.exit(2);
  }
  writeFileSync(path, src.replace(re, `$1"${version}"$2`));
}

function stampCabal(cabalVersion) {
  const path = resolve(REPO_ROOT, "haskell/katari/package.yaml");
  const src = readFileSync(path, "utf8");
  const re = /^version:\s*\d+(?:\.\d+)*\s*$/m;
  if (!re.test(src)) {
    console.error(`error: 'version:' line not found in ${path}`);
    process.exit(2);
  }
  writeFileSync(path, src.replace(re, `version: ${cabalVersion}`));
}

function tsPackageJsons() {
  const root = resolve(REPO_ROOT, "typescript/packages");
  const out = [];
  for (const name of readdirSync(root)) {
    const pkgPath = join(root, name, "package.json");
    try {
      statSync(pkgPath);
      out.push(pkgPath);
    } catch {
      // skip dirs without a package.json
    }
  }
  out.sort();
  return out;
}

function stampPackageJson(path, version) {
  const pkg = JSON.parse(readFileSync(path, "utf8"));
  pkg.version = version;
  writeFileSync(path, `${JSON.stringify(pkg, null, 2)}\n`);
}
