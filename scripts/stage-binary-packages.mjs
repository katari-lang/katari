#!/usr/bin/env node
// Stages `@katari-lang/cli-<platform>` npm package directories ready
// for publish.
//
// Inputs (default paths, override via env):
//   - `.binaries/katari-<version>-<platform>.tar.gz` for each platform.
//     Source: `release-katari.yml` uploads these to GitHub Releases;
//     the publish workflow downloads them with `gh release download`.
//
// Outputs:
//   - `.staged/<platform>/package.json`
//   - `.staged/<platform>/bin/katari` (chmod +x)
//   - `.staged/<platform>/README.md`
//
// Usage:
//   node scripts/stage-binary-packages.mjs --version 0.1.0
//
// Platforms are hardcoded below. Keep in sync with:
//   - `.github/workflows/release-katari.yml` matrix
//   - `typescript/packages/katari/bin/katari.mjs` `supported` set
//   - `scripts/bump-versions.mjs` PLATFORMS list

import { execFileSync } from "node:child_process";
import { chmodSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const PLATFORMS = [
  { key: "linux-x64", os: "linux", cpu: "x64" },
  { key: "darwin-arm64", os: "darwin", cpu: "arm64" },
];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= process.argv.length) {
    throw new Error(`missing --${name} <value>`);
  }
  return process.argv[i + 1];
}

const version = arg("version");
const binariesDir = resolve(process.env.BINARIES_DIR ?? ".binaries");
const stagedDir = resolve(process.env.STAGED_DIR ?? ".staged");

rmSync(stagedDir, { recursive: true, force: true });
mkdirSync(stagedDir, { recursive: true });

for (const { key, os, cpu } of PLATFORMS) {
  const pkgDir = resolve(stagedDir, key);
  const binDir = resolve(pkgDir, "bin");
  mkdirSync(binDir, { recursive: true });

  const tarball = resolve(binariesDir, `katari-${version}-${key}.tar.gz`);
  // tar archives the file as `katari` at the root (see release-katari.yml).
  execFileSync("tar", ["xzf", tarball, "-C", binDir], { stdio: "inherit" });
  chmodSync(resolve(binDir, "katari"), 0o755);

  const pkg = {
    name: `@katari-lang/cli-${key}`,
    version,
    description: `Prebuilt katari binary for ${key}. Installed automatically as an optionalDependency of @katari-lang/cli; not usually consumed directly.`,
    license: "MIT",
    author: "yukikurage",
    repository: {
      type: "git",
      url: "git+https://github.com/katari-lang/katari.git",
    },
    homepage: "https://github.com/katari-lang/katari#readme",
    bugs: "https://github.com/katari-lang/katari/issues",
    os: [os],
    cpu: [cpu],
    // `bin` field is set even though we don't want a global command
    // installed from this package: it triggers npm's auto-chmod +x on
    // install, which would otherwise leave the binary with mode 644
    // and EACCES on spawn. String form makes the .bin/<name> shim use
    // the package's scope-stripped name (`cli-<plat>`), which is
    // harmless dead weight — the user-facing `katari` shim lives in
    // @katari-lang/cli and wins the .bin/katari slot. esbuild uses
    // the same workaround for its platform packages.
    bin: "bin/katari",
    files: ["bin", "README.md"],
  };

  writeFileSync(resolve(pkgDir, "package.json"), `${JSON.stringify(pkg, null, 2)}\n`);

  writeFileSync(
    resolve(pkgDir, "README.md"),
    `# @katari-lang/cli-${key}\n\n` +
      `Prebuilt katari binary for ${key}. This package is an internal artifact ` +
      `installed automatically as an \`optionalDependency\` of ` +
      `[\`@katari-lang/cli\`](https://www.npmjs.com/package/@katari-lang/cli). ` +
      `Install \`@katari-lang/cli\` instead.\n`,
  );

  console.log(`staged @katari-lang/cli-${key}@${version} at ${pkgDir}`);
}
