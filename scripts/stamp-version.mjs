// Stamp phase of a release: rewrite every version source of truth to one string, BEFORE tagging.
//
//   node scripts/stamp-version.mjs --version 0.1.0-rc7
//   git commit -am "release: 0.1.0-rc7" && git tag v0.1.0-rc7
//
// Sources of truth (verify-versions.mjs cross-checks the same set against the pushed tag):
//   - haskell/cli/VERSION                 — the one-line file `cliVersion` embeds; the version
//                                           users see from `katari --version`.
//   - haskell/*/package.yaml `version:`   — cabal placeholders, rewritten to X.Y.Z.0 (cabal
//                                           cannot represent a pre-release suffix).
//   - typescript/*/package.json `version` — every workspace package, the exact input string.
//     (examples/* stay 0.0.0 — they are never published.)

import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseVersionArgument, repoRoot, typescriptPackageDirs } from "./versions-common.mjs";

const version = parseVersionArgument(process.argv, "stamp-version");
const release = version.split("-")[0];

const versionFile = join(repoRoot, "haskell/cli/VERSION");
writeFileSync(versionFile, `${version}\n`);
console.log(`stamped haskell/cli/VERSION -> ${version}`);

for (const name of readdirSync(join(repoRoot, "haskell"))) {
  const packageYaml = join(repoRoot, "haskell", name, "package.yaml");
  let source;
  try {
    source = readFileSync(packageYaml, "utf8");
  } catch {
    continue;
  }
  const stamped = source.replace(/^version: .*$/m, `version: ${release}.0`);
  if (stamped === source && !source.includes(`version: ${release}.0`)) {
    console.error(`stamp-version: no version: field found in ${packageYaml}`);
    process.exit(2);
  }
  writeFileSync(packageYaml, stamped);
  console.log(`stamped haskell/${name}/package.yaml -> ${release}.0`);
}

for (const dir of typescriptPackageDirs()) {
  const manifestPath = join(dir, "package.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  manifest.version = version;
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`stamped ${manifestPath} -> ${version}`);
}
