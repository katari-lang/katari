// Post-pack smoke for the published npm CLI (@katari-lang/cli) — the one shipped artifact with no
// unit coverage. It is a thin Node shim (typescript/cli/bin/katari.mjs) that, at runtime, resolves
// the prebuilt katari binary out of the matching `@katari-lang/cli-<platform>` package and forwards
// argv / stdio / exit code. This smoke exercises that path end to end against a REAL pack:
//
//   1. `pnpm pack` the shim, so we test the exact tarball a publish would upload (and prove the
//      workspace:* dependency ranges got rewritten to concrete versions on the way out).
//   2. Stage a throwaway `@katari-lang/cli-<platform>` package whose bin/katari IS the stack-built
//      binary, laid out in a temp node_modules exactly where the shim's require.resolve looks.
//   3. Run `katari --version` / `katari --help` THROUGH the shim and assert it located the binary,
//      forwarded the flags, and mirrored the child's exit code.
//
// Why staging instead of an env override: the shim has no env var for the MAIN binary — it is found
// only by resolving the platform package from node_modules (the KATARI_*_BIN overrides are for the
// bundle / mcp helper CLIs, not this). A publish injects those platform packages as
// optionalDependencies (scripts/bump-versions.mjs) pointing at registry tarballs that do not exist
// locally, so a bare `pnpm pack` + install has no binary to run. Standing up the platform package
// ourselves, pointed at the stack build, is the faithful local stand-in.
//
//   node scripts/smoke-npm-cli.mjs          # resolves the binary via `stack path`
//   KATARI_SMOKE_BIN=/abs/path/to/katari node scripts/smoke-npm-cli.mjs

import { execFileSync } from "node:child_process";
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

// The shim only ships prebuilt binaries for these; must stay in sync with typescript/cli/bin/katari.mjs.
const supportedPlatforms = new Set(["linux-x64", "darwin-arm64"]);
const platformKey = `${process.platform}-${process.arch}`;

function fail(message) {
  console.error(`smoke-npm-cli: ${message}`);
  process.exit(1);
}

function run(command, args, options = {}) {
  return execFileSync(command, args, { encoding: "utf8", ...options });
}

if (!supportedPlatforms.has(platformKey)) {
  // The shim has no binary for this platform, so there is nothing to smoke here. This is not a
  // failure of the CLI — the runner just is not one of the two release targets.
  console.log(`smoke-npm-cli: no prebuilt platform for ${platformKey}; skipping (release targets: ${[...supportedPlatforms].join(", ")}).`);
  process.exit(0);
}

// ── 1. Locate the stack-built binary the staged platform package will carry. ──────────────────────
let binaryPath = process.env.KATARI_SMOKE_BIN;
if (binaryPath === undefined || binaryPath === "") {
  const installRoot = run("stack", ["path", "--local-install-root"], { cwd: repoRoot }).trim();
  binaryPath = join(installRoot, "bin", "katari");
}
if (!existsSync(binaryPath)) {
  fail(`no katari binary at ${binaryPath}. Build it first: stack build katari-cli:katari (or set KATARI_SMOKE_BIN).`);
}

const workDir = mkdtempSync(join(tmpdir(), "katari-cli-smoke-"));
let failed = false;
try {
  // ── 2. Pack the shim exactly as a publish would, into the temp dir. ─────────────────────────────
  run("pnpm", ["--filter", "@katari-lang/cli", "pack", "--pack-destination", workDir], { cwd: repoRoot, stdio: ["ignore", "inherit", "inherit"] });
  const tarball = readdirSync(workDir).find((name) => name.endsWith(".tgz"));
  if (tarball === undefined) fail(`pnpm pack produced no .tgz in ${workDir}`);
  console.log(`smoke-npm-cli: packed ${tarball}`);

  // Extract; npm/pnpm tarballs put everything under a top-level `package/`.
  const extractDir = join(workDir, "extract");
  mkdirSync(extractDir, { recursive: true });
  run("tar", ["xzf", join(workDir, tarball), "-C", extractDir]);
  const shimPackageDir = join(extractDir, "package");

  // ── Assert pack rewrote every workspace:* range to a concrete version. ──────────────────────────
  // A leaked `workspace:` protocol would make the published tarball uninstallable off the monorepo.
  const shimManifest = JSON.parse(readFileSync(join(shimPackageDir, "package.json"), "utf8"));
  for (const section of ["dependencies", "optionalDependencies", "peerDependencies"]) {
    for (const [name, range] of Object.entries(shimManifest[section] ?? {})) {
      if (typeof range === "string" && range.startsWith("workspace:")) {
        fail(`packed shim still declares ${name}: "${range}" — pnpm pack did not resolve the workspace range`);
      }
    }
  }
  console.log("smoke-npm-cli: workspace:* ranges resolved in the packed manifest");

  // ── 3. Lay out a temp node_modules the shim can resolve against. ────────────────────────────────
  //   node_modules/@katari-lang/cli            ← the packed shim
  //   node_modules/@katari-lang/cli-<platform> ← the stack binary, where require.resolve looks
  const nodeModules = join(workDir, "consumer", "node_modules", "@katari-lang");
  const shimInstallDir = join(nodeModules, "cli");
  mkdirSync(shimInstallDir, { recursive: true });
  cpSync(shimPackageDir, shimInstallDir, { recursive: true });

  const platformDir = join(nodeModules, `cli-${platformKey}`);
  const platformBinDir = join(platformDir, "bin");
  mkdirSync(platformBinDir, { recursive: true });
  cpSync(binaryPath, join(platformBinDir, "katari"));
  chmodSync(join(platformBinDir, "katari"), 0o755);
  // Mirror the shape scripts/stage-binary-packages.mjs publishes, so the resolution target is realistic.
  writeFileSync(
    join(platformDir, "package.json"),
    `${JSON.stringify({ name: `@katari-lang/cli-${platformKey}`, version: shimManifest.version, bin: { [`katari-${platformKey}`]: "bin/katari" } }, null, 2)}\n`,
  );

  const shimEntry = join(shimInstallDir, "bin", "katari.mjs");

  // The shim is what we are testing; run it under the current node so version/exit-code forwarding is exercised.
  const checks = [
    { flag: "--version", expect: /\d+\.\d+\.\d+/ },
    { flag: "--help", expect: /katari/i },
  ];
  for (const { flag, expect } of checks) {
    let output;
    try {
      output = run(process.execPath, [shimEntry, flag], { cwd: workDir });
    } catch (error) {
      console.error(`smoke-npm-cli: \`katari ${flag}\` failed (exit ${error.status})`);
      console.error((error.stdout ?? "") + (error.stderr ?? ""));
      failed = true;
      continue;
    }
    if (!expect.test(output)) {
      console.error(`smoke-npm-cli: \`katari ${flag}\` output did not match ${expect}:\n${output}`);
      failed = true;
      continue;
    }
    console.log(`smoke-npm-cli: \`katari ${flag}\` OK -> ${output.trim().split("\n")[0]}`);
  }
} finally {
  rmSync(workDir, { recursive: true, force: true });
}

if (failed) process.exit(1);
console.log("smoke-npm-cli: PASS");
