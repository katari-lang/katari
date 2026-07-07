#!/usr/bin/env node
// Place a `katari-lsp` binary into `typescript/vscode/bin/` so the packaged VSIX (and an Extension
// Development Host launched from this directory) resolves the bundled server instead of PATH.
//
// Source resolution:
//   KATARI_LSP_BIN=/abs/path/katari-lsp   — an explicit binary (what the release CI passes after
//                                            extracting a platform tarball), or
//   the local `stack build` output          — `$(stack path --local-install-root)/bin/katari-lsp`,
//                                            for a from-source developer testing the packaging path.
//
// The binary is NOT committed (see .gitignore); this script (re)materialises it on demand.

import { execFileSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const extensionRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const target = join(extensionRoot, "bin", "katari-lsp");

function resolveSource() {
  const explicit = process.env.KATARI_LSP_BIN;
  if (explicit !== undefined && explicit.length > 0) {
    if (!existsSync(explicit)) {
      console.error(`copy-server-binary: KATARI_LSP_BIN=${explicit} does not exist`);
      process.exit(1);
    }
    return explicit;
  }
  // Fall back to the local stack build (a repo checkout with a Haskell toolchain).
  try {
    const installRoot = execFileSync("stack", ["path", "--local-install-root"], {
      cwd: extensionRoot,
      encoding: "utf8",
    }).trim();
    const candidate = join(installRoot, "bin", "katari-lsp");
    if (existsSync(candidate)) return candidate;
    console.error(
      `copy-server-binary: no katari-lsp at ${candidate}. Run \`stack build katari-lsp\` first, ` +
        "or set KATARI_LSP_BIN to a prebuilt binary.",
    );
    process.exit(1);
  } catch (error) {
    console.error(
      "copy-server-binary: could not locate a katari-lsp binary. Set KATARI_LSP_BIN, or build one " +
        `with stack. (${error instanceof Error ? error.message : String(error)})`,
    );
    process.exit(1);
  }
}

const source = resolveSource();
mkdirSync(dirname(target), { recursive: true });
copyFileSync(source, target);
chmodSync(target, 0o755);
console.log(`copy-server-binary: ${source} -> ${target}`);
