#!/usr/bin/env node
// `katari-mcp` — the CLI front for the MCP helpers the Haskell `katari` binary spawns. Two verbs:
//
//   - `login --url <server> [--scope <scope>]` runs the authorization-code + PKCE flow (dynamic
//     client registration, loopback redirect) and writes the credential JSON —
//     `{ tokens, clientInformation, resourceUrl }` — to stdout. `katari mcp login` stores the blob
//     as a project secret.
//   - `list-tools --url <server> [--header k=v]... [--oauth [--scope <scope>]]` connects, lists the
//     server's tools, and writes `{ "tools": [...] }` to stdout. `katari mcp pull` generates a typed
//     binding module from it; `--oauth` runs the same interactive flow as `login` but keeps the
//     credential in memory (nothing is stored).
//
// All human-facing output (the authorization URL, progress) goes to stderr so stdout stays pure JSON.
// Exit codes: 0 success (JSON on stdout) · 1 flow/listing failure · 2 usage error.

import { spawn } from "node:child_process";
import { parseLoginArguments, performLogin } from "./index.js";
import { parseListToolsArguments, performListTools } from "./list-tools.js";

function printHelp(): void {
  process.stdout.write(
    [
      "Usage: katari-mcp login --url <server> [--scope <scope>]",
      "       katari-mcp list-tools --url <server> [--header k=v]... [--oauth [--scope <scope>]]",
      "",
      "login runs the OAuth 2.1 authorization-code + PKCE flow against the MCP server at <server>:",
      "registers a client dynamically, opens the authorization URL (printed to stderr — a local",
      "browser is attempted best-effort), receives the redirect on a loopback port, exchanges the",
      "code, and writes the credential JSON { tokens, clientInformation, resourceUrl } to stdout.",
      "Storage is the caller's job: `katari mcp login` saves the blob as a project secret.",
      "",
      "list-tools connects to the server (headers riding on every request, or --oauth running the",
      "same interactive flow with the credential kept in memory), lists its tools, and writes",
      '{ "tools": [{ "name", "description", "inputSchema", "outputSchema"? }] } to stdout.',
      "`katari mcp pull` generates a typed binding module from that listing.",
      "",
      "Exit codes: 0 success · 1 failure · 2 usage error",
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

/** The shared interactive-flow callbacks: progress to stderr (stdout is data), browser best-effort. */
const callbacks = {
  log: (line: string) => process.stderr.write(`${line}\n`),
  openBrowser,
};

async function runLogin(rest: string[]): Promise<never> {
  let parsed: ReturnType<typeof parseLoginArguments>;
  try {
    parsed = parseLoginArguments(rest);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 2);
  }
  try {
    const credential = await performLogin(parsed, callbacks);
    process.stdout.write(`${JSON.stringify(credential)}\n`);
    // The loopback listener is closed, but a lingering keep-alive socket must not hold the process.
    process.exit(0);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 1);
  }
}

async function runListTools(rest: string[]): Promise<never> {
  let parsed: ReturnType<typeof parseListToolsArguments>;
  try {
    parsed = parseListToolsArguments(rest);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 2);
  }
  try {
    const listing = await performListTools(parsed, callbacks);
    process.stdout.write(`${JSON.stringify(listing)}\n`);
    // The SDK client is closed, but a lingering keep-alive socket must not hold the process.
    process.exit(0);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 1);
  }
}

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  if (argv.length === 0 || argv.includes("--help") || argv.includes("-h")) {
    printHelp();
    process.exit(0);
  }
  const [subcommand, ...rest] = argv;
  switch (subcommand) {
    case "login":
      await runLogin(rest);
      break;
    case "list-tools":
      await runListTools(rest);
      break;
    default:
      bail(`unknown subcommand: ${subcommand ?? ""} (login and list-tools exist)`, 2);
  }
}

await main();
