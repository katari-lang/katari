// Assemble the platform-specific npm packages around the prebuilt `katari` binaries, for
// release-npm.yml to publish. Reads the tarballs release-katari attached to the GitHub Release
// (downloaded into BINARIES_DIR) and stages one publishable package per platform in STAGED_DIR.
//
//   BINARIES_DIR=.binaries STAGED_DIR=.staged node scripts/stage-binary-packages.mjs --version 0.1.0-rc7
//
// Expects: <BINARIES_DIR>/katari-<version>-<platform>.tar.gz containing a single `katari` binary.

import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BINARY_PLATFORMS, parseVersionArgument, repoRoot } from "./versions-common.mjs";

const version = parseVersionArgument(process.argv, "stage-binary-packages");
const binariesDir = process.env.BINARIES_DIR ?? join(repoRoot, ".binaries");
const stagedDir = process.env.STAGED_DIR ?? join(repoRoot, ".staged");

for (const { key, os, cpu } of BINARY_PLATFORMS) {
  const packageDir = join(stagedDir, key);
  const binDir = join(packageDir, "bin");
  rmSync(packageDir, { recursive: true, force: true });
  mkdirSync(binDir, { recursive: true });

  const tarball = join(binariesDir, `katari-${version}-${key}.tar.gz`);
  execFileSync("tar", ["xzf", tarball, "-C", binDir, "katari"]);
  chmodSync(join(binDir, "katari"), 0o755);

  writeFileSync(
    join(packageDir, "package.json"),
    `${JSON.stringify(
      {
        name: `@katari-lang/cli-${key}`,
        version,
        description: `Prebuilt katari binary for ${key}. Installed on demand by @katari-lang/cli; not meant to be depended on directly.`,
        license: "MIT",
        repository: {
          type: "git",
          url: "git+https://github.com/katari-lang/katari.git",
        },
        os: [os],
        cpu: [cpu],
        // The bin key is deliberately NOT "katari". A `bin` entry is still needed so npm marks
        // bin/katari executable (0o755) in the published tarball, but the user-facing `katari`
        // command belongs to the @katari-lang/cli shim (which resolves this binary by path, not by
        // name). Naming this "katari" too would make npm see two packages claiming
        // node_modules/.bin/katari and link NEITHER — breaking `npx katari`. A platform-qualified
        // name keeps the executable bit without colliding with the shim.
        bin: { [`katari-${key}`]: "bin/katari" },
        files: ["bin", "README.md"],
      },
      null,
      2,
    )}\n`,
  );
  writeFileSync(
    join(packageDir, "README.md"),
    `# @katari-lang/cli-${key}\n\nThe prebuilt \`katari\` binary for ${key}, installed on demand as an optional dependency of [\`@katari-lang/cli\`](https://www.npmjs.com/package/@katari-lang/cli). Install that package instead.\n`,
  );
  console.log(`staged ${packageDir}`);
}
