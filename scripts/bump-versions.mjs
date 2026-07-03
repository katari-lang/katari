// Publish-time injection: add the platform binary packages to the CLI shim's optionalDependencies
// immediately before `pnpm publish` (release-npm.yml). NOT part of stamp-version: the committed
// tree must stay installable before the first publish, and the binary packages do not exist on the
// registry until release-katari has uploaded their tarballs.
//
//   node scripts/bump-versions.mjs --version 0.1.0-rc7

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BINARY_PLATFORMS, parseVersionArgument, repoRoot } from "./versions-common.mjs";

const version = parseVersionArgument(process.argv, "bump-versions");

const manifestPath = join(repoRoot, "typescript/cli/package.json");
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
manifest.optionalDependencies = {
  ...manifest.optionalDependencies,
  ...Object.fromEntries(
    BINARY_PLATFORMS.map(({ key }) => [`@katari-lang/cli-${key}`, version]),
  ),
};
writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(
  `injected ${BINARY_PLATFORMS.map(({ key }) => `@katari-lang/cli-${key}@${version}`).join(", ")}`,
);
