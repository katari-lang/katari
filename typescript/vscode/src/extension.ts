// VSCode language client for Katari.
//
// Spawns the katari-lsp binary as a subprocess and connects it via stdio. The binary is resolved in
// three tiers (see `resolveServerPath`): an explicit `katari.server.path` setting wins, else the
// binary bundled inside the platform-specific VSIX (the marketplace / release-page install), else a
// plain `katari-lsp` on PATH (a from-source developer who ran `stack install katari-lsp`).

import { chmodSync, existsSync } from "node:fs";
import { join } from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("katari");
  const serverPath = resolveServerPath(context, config);
  const serverArgs = config.get<string[]>("server.args", []);

  const serverOptions: ServerOptions = {
    command: serverPath,
    args: serverArgs,
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: "katari" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.ktr"),
    },
  };

  client = new LanguageClient("katari", "Katari Language Server", serverOptions, clientOptions);

  // Surface start failures to the user immediately. Without this, a missing katari-lsp binary fails
  // silently and only the Output panel hints at the cause — too easy to miss when first installing.
  client.start().catch((err: unknown) => {
    const message = err instanceof Error ? err.message : String(err);
    void vscode.window.showErrorMessage(
      `Katari Language Server failed to start: ${message}. The server resolved to '${serverPath}'. ` +
        "Set 'katari.server.path' to a katari-lsp binary, or install one on PATH.",
    );
  });
  context.subscriptions.push({
    dispose: () => {
      client?.stop();
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

/**
 * Resolve the katari-lsp command in priority order:
 *   1. An explicit `katari.server.path` (workspace / user setting) — the escape hatch for a custom
 *      build or a non-standard install; used verbatim (an absolute path, or a name looked up on PATH).
 *   2. The binary bundled in this VSIX at `bin/katari-lsp` — present for a platform-specific install
 *      from the marketplace / release page. A VSIX is a zip, which can drop the POSIX executable bit,
 *      so it is restored before use.
 *   3. `katari-lsp` on PATH — the from-source developer path (`stack install katari-lsp`).
 *
 * The setting's `default` is `"katari-lsp"`, so `get` alone cannot tell an explicit choice from the
 * default; `inspect` is used to honour tier 1 only when the value was actually set.
 */
function resolveServerPath(
  context: vscode.ExtensionContext,
  config: vscode.WorkspaceConfiguration,
): string {
  const inspected = config.inspect<string>("server.path");
  const explicit =
    inspected?.workspaceFolderValue ?? inspected?.workspaceValue ?? inspected?.globalValue;
  if (typeof explicit === "string" && explicit.trim().length > 0) {
    return explicit;
  }

  const bundled = join(
    context.extensionPath,
    "bin",
    process.platform === "win32" ? "katari-lsp.exe" : "katari-lsp",
  );
  if (existsSync(bundled)) {
    if (process.platform !== "win32") {
      // Best effort — if the bit is already set (or we lack permission) the spawn still succeeds /
      // fails on its own terms; a chmod hiccup must not mask the real error.
      try {
        chmodSync(bundled, 0o755);
      } catch {
        // ignore
      }
    }
    return bundled;
  }

  return "katari-lsp";
}
