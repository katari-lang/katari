#!/usr/bin/env node
// Sets the `version` field on every publishable TS package to the
// given value, and **injects** the `@katari-lang/cli` shim's
// `optionalDependencies` so each `@katari-lang/cli-<platform>` entry
// points at the same version.
//
// optionalDependencies are intentionally absent from the committed
// source manifest so that pre-first-publish `pnpm install` doesn't
// fail trying to resolve not-yet-on-registry packages.
//
// `workspace:*` cross-references are left as-is; `pnpm publish`
// rewrites them on the fly using the registry-published versions of
// the same packages.
//
// Skips `katari-vscode` (published as VSIX, not npm).
//
// Usage:
//   node scripts/bump-versions.mjs --version 0.1.0

import { readFileSync, writeFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// (workspace dir name, npm name). Directory layout is decoupled from
// npm scope so we can rename one without churning the other.
const PUBLISHABLE = [
  { dir: "katari",            name: "@katari-lang/cli"        },
  { dir: "katari-runtime",    name: "@katari-lang/runtime"    },
  { dir: "katari-port",       name: "@katari-lang/port"       },
  { dir: "katari-bundle",     name: "@katari-lang/bundle"     },
  { dir: "katari-api-server", name: "@katari-lang/api-server" },
];

const PLATFORMS = ["linux-x64", "darwin-arm64", "darwin-x64"];

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1 || i + 1 >= process.argv.length) {
    throw new Error(`missing --${name} <value>`);
  }
  return process.argv[i + 1];
}

const version = arg("version");

for (const { dir, name } of PUBLISHABLE) {
  const pkgPath = resolve(REPO_ROOT, "typescript/packages", dir, "package.json");
  const pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
  pkg.version = version;

  if (name === "@katari-lang/cli") {
    pkg.optionalDependencies ??= {};
    for (const plat of PLATFORMS) {
      pkg.optionalDependencies[`@katari-lang/cli-${plat}`] = version;
    }
  }

  writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
  console.log(`bumped ${name} (${dir}) to ${version}`);
}
