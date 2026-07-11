// VSCode integration for Katari: the language client plus the "Katari: ..." palette commands.
//
// The language client spawns the katari-lsp binary as a subprocess and connects it via stdio. The
// binary is resolved in three tiers (see `resolveServerPath`): an explicit `katari.server.path`
// setting wins, else the binary bundled inside the platform-specific VSIX (the marketplace /
// release-page install), else a plain `katari-lsp` on PATH (a from-source developer who ran
// `stack install katari-lsp`).
//
// The palette commands drive the katari CLI (check / build / apply / mcp login / mcp pull) in one
// shared integrated terminal rather than a background process, because several flows are
// interactive: `mcp login` prints an authorization URL and waits, and `apply` may prompt. The CLI
// is resolved separately from the server (see `resolveCliPath`) since the VSIX bundles no CLI.

import { chmodSync, existsSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import * as vscode from "vscode";
import {
  LanguageClient,
  type LanguageClientOptions,
  type ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  startLanguageClient(context);
  registerCommands(context);
  context.subscriptions.push({
    dispose: () => {
      client?.stop();
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

// ---------------------------------------------------------------------------
// Language client
// ---------------------------------------------------------------------------

function startLanguageClient(context: vscode.ExtensionContext): void {
  const config = vscode.workspace.getConfiguration("katari");
  const serverPath = resolveServerPath(context, config);
  const serverArguments = config.get<string[]>("server.args", []);

  const serverOptions: ServerOptions = {
    command: serverPath,
    args: serverArguments,
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
}

// A restart rebuilds the client from the current configuration instead of calling
// `LanguageClient.restart()`, because the server command was baked into `ServerOptions` when the
// client was constructed — rebuilding is what makes "change katari.server.path, then restart" work
// without reloading the window. `dispose` (not `stop`) so the old client's watchers go with it.
async function restartLanguageServer(context: vscode.ExtensionContext): Promise<void> {
  const previous = client;
  client = undefined;
  if (previous !== undefined) {
    try {
      await previous.dispose();
    } catch {
      // The server may have crashed or never come up; a failed teardown must not block the restart.
    }
  }
  startLanguageClient(context);
}

/**
 * Resolve the katari-lsp command in priority order:
 *   1. An explicit `katari.server.path` (workspace / user setting) — the escape hatch for a custom
 *      build or a non-standard install; used verbatim (an absolute path, or a name looked up on PATH).
 *   2. The binary bundled in this VSIX at `bin/katari-lsp` — present for a platform-specific install
 *      from the marketplace / release page.
 *   3. `katari-lsp` on PATH — the from-source developer path (`stack install katari-lsp`).
 */
function resolveServerPath(
  context: vscode.ExtensionContext,
  config: vscode.WorkspaceConfiguration,
): string {
  const bundled = join(
    context.extensionPath,
    "bin",
    process.platform === "win32" ? "katari-lsp.exe" : "katari-lsp",
  );
  return resolveExecutable(config, "server.path", bundled, "katari-lsp");
}

/**
 * Resolve the katari CLI command for the palette commands. Same shape as `resolveServerPath` minus
 * the bundled tier — the VSIX ships no CLI, so it is the `katari.cli.path` setting, else `katari`
 * on PATH.
 */
function resolveCliPath(config: vscode.WorkspaceConfiguration): string {
  return resolveExecutable(config, "cli.path", undefined, "katari");
}

/**
 * The shared binary-resolution ladder: explicit setting, else the bundled binary (when the caller
 * has one), else a bare name for the shell's PATH lookup.
 *
 * The setting's `default` in package.json equals the PATH fallback, so `get` alone cannot tell an
 * explicit choice from the default; `inspect` is used to honour the setting only when it was
 * actually set.
 */
function resolveExecutable(
  config: vscode.WorkspaceConfiguration,
  settingKey: string,
  bundledPath: string | undefined,
  pathFallback: string,
): string {
  const inspected = config.inspect<string>(settingKey);
  const explicit =
    inspected?.workspaceFolderValue ?? inspected?.workspaceValue ?? inspected?.globalValue;
  if (typeof explicit === "string" && explicit.trim().length > 0) {
    return explicit;
  }

  if (bundledPath !== undefined && existsSync(bundledPath)) {
    if (process.platform !== "win32") {
      // A VSIX is a zip, which can drop the POSIX executable bit, so restore it. Best effort — if
      // the bit is already set (or we lack permission) the spawn still succeeds / fails on its own
      // terms; a chmod hiccup must not mask the real error.
      try {
        chmodSync(bundledPath, 0o755);
      } catch {
        // ignore
      }
    }
    return bundledPath;
  }

  return pathFallback;
}

// ---------------------------------------------------------------------------
// CLI palette commands
// ---------------------------------------------------------------------------

type CliCommand = {
  id: string;
  // Mirrors the title declared in package.json's `contributes.commands`; kept here so error
  // messages can name the palette entry the user actually invoked.
  title: string;
  // Builds the argument vector passed to the katari CLI (the `-C <root>` flag is appended by the
  // shared runner). Async because some commands prompt; `undefined` means the user dismissed a
  // prompt, which is a cancellation and not an error.
  buildArguments: (projectRoot: string) => Promise<string[] | undefined>;
};

const cliCommands: CliCommand[] = [
  {
    id: "katari.check",
    title: "Katari: Check project",
    buildArguments: async () => ["check"],
  },
  {
    id: "katari.build",
    title: "Katari: Build project",
    buildArguments: async () => ["build"],
  },
  {
    id: "katari.apply",
    title: "Katari: Apply (deploy) project",
    buildArguments: async () => ["apply"],
  },
  {
    id: "katari.mcpLogin",
    title: "Katari: MCP login (OAuth)",
    buildArguments: async () => {
      const url = await promptForMcpServerUrl();
      if (url === undefined) {
        return undefined;
      }
      const name = await promptForCredentialName();
      if (name === undefined) {
        return undefined;
      }
      return ["mcp", "login", "--url", url, "--name", name];
    },
  },
  {
    id: "katari.mcpPull",
    title: "Katari: Generate MCP tool bindings",
    buildArguments: async (projectRoot) => {
      const url = await promptForMcpServerUrl();
      if (url === undefined) {
        return undefined;
      }
      const outputPath = await promptForBindingsOutputPath(projectRoot);
      if (outputPath === undefined) {
        return undefined;
      }
      // The pull runs in the terminal, so completion is observed by watching for the output file
      // to be (re)written rather than by a process exit code.
      openDocumentWhenWritten(outputPath);
      return ["mcp", "pull", "--url", url, "--out", outputPath];
    },
  },
];

function registerCommands(context: vscode.ExtensionContext): void {
  for (const command of cliCommands) {
    context.subscriptions.push(
      vscode.commands.registerCommand(command.id, () => runCliCommand(command)),
    );
  }
  context.subscriptions.push(
    vscode.commands.registerCommand("katari.restartLanguageServer", () =>
      restartLanguageServer(context),
    ),
  );
  context.subscriptions.push(
    vscode.window.onDidCloseTerminal((closed) => {
      if (closed === katariTerminal) {
        katariTerminal = undefined;
      }
    }),
  );
}

async function runCliCommand(command: CliCommand): Promise<void> {
  const projectRoot = findProjectRoot();
  if (projectRoot === undefined) {
    void vscode.window.showErrorMessage(
      `${command.title}: no katari.toml found. Open a Katari project folder ` +
        "(or a file inside one) and try again.",
    );
    return;
  }

  const builtArguments = await command.buildArguments(projectRoot);
  if (builtArguments === undefined) {
    return;
  }

  // Resolved per invocation (not once at activation) so a changed `katari.cli.path` takes effect
  // without reloading the window. `-C` pins the project explicitly because the terminal's cwd is
  // whatever the user last cd'd to.
  const cliPath = resolveCliPath(vscode.workspace.getConfiguration("katari"));
  runInKatariTerminal([cliPath, ...builtArguments, "-C", projectRoot]);
}

/**
 * Find the nearest enclosing katari.toml, preferring the active editor's file over the workspace
 * folders — in a multi-root or nested-project workspace, the file being edited is the better signal
 * for which project the user means.
 */
function findProjectRoot(): string | undefined {
  const startingPoints: string[] = [];
  const activeDocument = vscode.window.activeTextEditor?.document.uri;
  if (activeDocument !== undefined && activeDocument.scheme === "file") {
    startingPoints.push(dirname(activeDocument.fsPath));
  }
  for (const folder of vscode.workspace.workspaceFolders ?? []) {
    if (folder.uri.scheme === "file") {
      startingPoints.push(folder.uri.fsPath);
    }
  }

  for (const start of startingPoints) {
    let current = start;
    for (;;) {
      if (existsSync(join(current, "katari.toml"))) {
        return current;
      }
      const parent = dirname(current);
      if (parent === current) {
        break;
      }
      current = parent;
    }
  }
  return undefined;
}

// ---------------------------------------------------------------------------
// Terminal plumbing
// ---------------------------------------------------------------------------

let katariTerminal: vscode.Terminal | undefined;

// One shared "Katari" terminal keeps successive runs (and their scrollback) in one place instead of
// spawning a tab per command. Recreated when the previous one was closed or its shell exited.
function runInKatariTerminal(commandLine: string[]): void {
  if (katariTerminal === undefined || katariTerminal.exitStatus !== undefined) {
    katariTerminal = vscode.window.createTerminal("Katari");
  }
  // Focus the terminal (show without preserveFocus): the interactive commands expect keyboard input
  // there, and check/build users are reading its output anyway.
  katariTerminal.show();
  katariTerminal.sendText(commandLine.map(quoteForShell).join(" "), true);
}

/**
 * Quote one argument for the user's interactive shell. The exact shell is unknowable from the API,
 * so this targets the two families VSCode spawns: POSIX-ish shells (sh / bash / zsh / fish all
 * accept the close-quote escape-quote reopen-quote idiom) and Windows shells (PowerShell and cmd
 * both accept doubled double-quotes inside a double-quoted string).
 */
function quoteForShell(argument: string): string {
  if (/^[A-Za-z0-9@%+=:,._/-]+$/.test(argument)) {
    return argument;
  }
  if (process.platform === "win32") {
    return `"${argument.replace(/"/g, '""')}"`;
  }
  return `'${argument.replace(/'/g, "'\\''")}'`;
}

// ---------------------------------------------------------------------------
// Prompts for the mcp commands
// ---------------------------------------------------------------------------

async function promptForMcpServerUrl(): Promise<string | undefined> {
  const value = await vscode.window.showInputBox({
    title: "MCP server URL",
    prompt: "The MCP server to connect to (the URL programs pass to mcp.provide)",
    placeHolder: "https://example.com/mcp",
    // OAuth flows send the user to a browser mid-command; losing the input on focus change would
    // force retyping.
    ignoreFocusOut: true,
    validateInput: (input) => {
      let parsed: URL;
      try {
        parsed = new URL(input.trim());
      } catch {
        return "Enter a full URL, including the scheme (https://...).";
      }
      return parsed.protocol === "http:" || parsed.protocol === "https:"
        ? undefined
        : "The URL must use http or https.";
    },
  });
  return value?.trim();
}

async function promptForCredentialName(): Promise<string | undefined> {
  const value = await vscode.window.showInputBox({
    title: "Credential name",
    prompt: 'Programs reference it as auth = mcp.oauth(name = "..."); stored as mcp.oauth.<name>',
    placeHolder: "github",
    ignoreFocusOut: true,
    validateInput: (input) => {
      const trimmed = input.trim();
      if (trimmed.length === 0) {
        return "The credential name must not be empty.";
      }
      // The name becomes part of the env key mcp.oauth.<name>; whitespace would make it
      // unreferenceable from Katari source.
      return /\s/.test(trimmed) ? "The credential name must not contain whitespace." : undefined;
    },
  });
  return value?.trim();
}

async function promptForBindingsOutputPath(projectRoot: string): Promise<string | undefined> {
  // Default into src/ when the project has one — that is where katari.toml projects keep sources —
  // but never invent the directory from a save dialog.
  const sourceDirectory = join(projectRoot, "src");
  const defaultDirectory = existsSync(sourceDirectory) ? sourceDirectory : projectRoot;
  const chosen = await vscode.window.showSaveDialog({
    title: "Generated bindings file",
    defaultUri: vscode.Uri.file(join(defaultDirectory, "mcp-tools.ktr")),
    filters: { "Katari source": ["ktr"] },
  });
  return chosen?.fsPath;
}

/**
 * Open `filePath` in an editor once its mtime moves past the moment the command was issued.
 * Polling is the honest option here: the CLI runs in the integrated terminal, and the stable
 * (engine 1.80) API has no event for "that command finished". Gives up silently after the deadline
 * — a failed pull already explained itself in the terminal.
 */
function openDocumentWhenWritten(filePath: string): void {
  // A small backdate absorbs filesystems that round mtimes down to whole seconds.
  const issuedAt = Date.now() - 2000;
  const deadline = Date.now() + 5 * 60 * 1000;
  const poll = (): void => {
    let modifiedAt: number | undefined;
    try {
      modifiedAt = statSync(filePath).mtimeMs;
    } catch {
      modifiedAt = undefined;
    }
    if (modifiedAt !== undefined && modifiedAt >= issuedAt) {
      void vscode.window.showTextDocument(vscode.Uri.file(filePath), { preview: false });
      return;
    }
    if (Date.now() < deadline) {
      setTimeout(poll, 500);
    }
  };
  setTimeout(poll, 500);
}
