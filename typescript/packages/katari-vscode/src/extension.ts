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

  const serverOptions: ServerOptions = {
    command: serverPath,
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

  client.start();
  context.subscriptions.push({
    dispose: () => {
      client?.stop();
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
