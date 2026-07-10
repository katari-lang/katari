#!/usr/bin/env node
// `katari-mcp` — the CLI front for the MCP OAuth login flow. `login --url <server> [--scope <scope>]`
// runs the authorization-code + PKCE flow (dynamic client registration, loopback redirect) and writes
// the credential JSON — `{ tokens, clientInformation, resourceUrl }` — to stdout. The Haskell
// `katari mcp login` spawns this with stdio piped and stores the blob as the project secret; all
// human-facing output (the authorization URL, progress) goes to stderr so stdout stays pure JSON.
//
// Exit codes: 0 success (credential JSON on stdout) · 1 flow failure · 2 usage error.

import { spawn } from "node:child_process";
import { parseLoginArguments, performLogin } from "./index.js";

function printHelp(): void {
  process.stdout.write(
    [
      "Usage: katari-mcp login --url <server> [--scope <scope>]",
      "",
      "Runs the OAuth 2.1 authorization-code + PKCE flow against the MCP server at <server>:",
      "registers a client dynamically, opens the authorization URL (printed to stderr — a local",
      "browser is attempted best-effort), receives the redirect on a loopback port, exchanges the",
      "code, and writes the credential JSON { tokens, clientInformation, resourceUrl } to stdout.",
      "",
      "Storage is the caller's job: `katari mcp login` saves the blob as a project secret.",
      "",
      "Exit codes: 0 success · 1 flow failure · 2 usage error",
      "",
    ].join("\n"),
  );
}

function bail(message: string, code: number): never {
  process.stderr.write(`katari-mcp: ${message}\n`);
  process.exit(code);
}

/** Best-effort local browser launch; when it fails the printed URL is the fallback, so errors are
 *  swallowed deliberately. */
function openBrowser(url: string): void {
  const command = process.platform === "darwin" ? "open" : "xdg-open";
  try {
    const child = spawn(command, [url], { stdio: "ignore", detached: true });
    child.on("error", () => {});
    child.unref();
  } catch {
    // Nothing: the URL is already on stderr.
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv.length === 0 || argv.includes("--help") || argv.includes("-h")) {
    printHelp();
    process.exit(0);
  }
  const [subcommand, ...rest] = argv;
  if (subcommand !== "login") {
    bail(`unknown subcommand: ${subcommand ?? ""} (only \`login\` exists)`, 2);
  }
  let parsed: ReturnType<typeof parseLoginArguments>;
  try {
    parsed = parseLoginArguments(rest);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 2);
  }
  try {
    const credential = await performLogin(parsed, {
      log: (line) => process.stderr.write(`${line}\n`),
      openBrowser,
    });
    process.stdout.write(`${JSON.stringify(credential)}\n`);
    // The loopback listener is closed, but a lingering keep-alive socket must not hold the process.
    process.exit(0);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 1);
  }
}

await main();
