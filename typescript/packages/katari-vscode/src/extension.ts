// VSCode language client for Katari.
//
// Spawns the katari-lsp binary as a subprocess (path is configurable
// via `katari.server.path`, default looked up on PATH) and connects
// it via stdio.

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
  const serverPath = config.get<string>("server.path", "katari-lsp");
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

  client = new LanguageClient(
    "katari",
    "Katari Language Server",
    serverOptions,
    clientOptions,
  );

  // Surface start failures to the user immediately. Without this,
  // a missing `katari-lsp` binary fails silently and only the Output
  // panel hints at the cause — too easy to miss when first installing.
  client.start().catch((err: unknown) => {
    const message =
      err instanceof Error ? err.message : String(err);
    void vscode.window.showErrorMessage(
      `Katari Language Server failed to start: ${message}. Check 'katari.server.path' (currently '${serverPath}') and make sure katari-lsp is installed.`,
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
