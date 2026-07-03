// Shared bits of the version tooling: the repo root, the version-string format, and the workspace
// package enumeration — so stamp / verify / bump agree on what "all the versions" means.

import { readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

/** X.Y.Z with an optional pre-release suffix (0.1.0, 0.1.0-rc6, 0.1.0-beta.1). */
export const VERSION_PATTERN = /^(\d+\.\d+\.\d+)(-[A-Za-z0-9.-]+)?$/;

/** The platform-specific binary packages published alongside the CLI shim. Must stay in sync with
 *  the release-katari build matrix and typescript/cli/bin/katari.mjs's supported set. */
export const BINARY_PLATFORMS = [
  { key: "linux-x64", os: "linux", cpu: "x64" },
  { key: "darwin-arm64", os: "darwin", cpu: "arm64" },
];

/** Read `--version <v>` from argv, validating the format. */
export function parseVersionArgument(argv, scriptName) {
  const index = argv.indexOf("--version");
  const version = index === -1 ? undefined : argv[index + 1];
  if (version === undefined || !VERSION_PATTERN.test(version)) {
    console.error(`${scriptName}: pass --version X.Y.Z[-prerelease]`);
    process.exit(2);
  }
  return version;
}

/** Read `--tag vX.Y.Z[-pre]` from argv and return the version it names. */
export function parseTagArgument(argv, scriptName) {
  const index = argv.indexOf("--tag");
  const tag = index === -1 ? undefined : argv[index + 1];
  if (tag === undefined || !tag.startsWith("v") || !VERSION_PATTERN.test(tag.slice(1))) {
    console.error(`${scriptName}: pass --tag vX.Y.Z[-prerelease]`);
    process.exit(2);
  }
  return tag.slice(1);
}

/** Every typescript workspace package directory (typescript/<name> with a package.json). */
export function typescriptPackageDirs() {
  const base = join(repoRoot, "typescript");
  return readdirSync(base)
    .map((name) => join(base, name))
    .filter((dir) => {
      try {
        return statSync(join(dir, "package.json")).isFile();
      } catch {
        return false;
      }
    });
}
