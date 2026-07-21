#!/usr/bin/env node
// `katari-mcp` — the CLI front for the MCP helper the Haskell `katari` binary spawns. One verb:
//
//   - `list-tools --url <server> [--header k=v]... [--oauth [--scope <scope>]]` connects, lists the
//     server's tools, and writes `{ "tools": [...] }` to stdout. `katari mcp pull` generates a typed
//     binding module from it. `--oauth` runs the OAuth 2.1 authorization-code + PKCE flow (dynamic
//     client registration, loopback redirect) and keeps the credential in memory for that one listing
//     — nothing is stored. Runtime credential storage and the human-facing authorization prompt now
//     live in the runtime as an OAuth escalation, so this helper is a listing concern only.
//
// All human-facing output (the authorization URL, progress) goes to stderr so stdout stays pure JSON.
// Exit codes: 0 success (JSON on stdout) · 1 listing failure · 2 usage error.

import { spawn } from "node:child_process";
import { parseListToolsArguments, performListTools } from "./list-tools.js";

function printHelp(): void {
  process.stdout.write(
    [
      "Usage: katari-mcp list-tools --url <server> [--header k=v]... [--oauth [--scope <scope>]]",
      "",
      "list-tools connects to the server (headers riding on every request, or --oauth running the",
      "OAuth 2.1 authorization-code + PKCE flow with the credential kept in memory), lists its tools,",
      'and writes { "tools": [{ "name", "description", "inputSchema", "outputSchema"? }] } to stdout.',
      "`katari mcp pull` generates a typed binding module from that listing. With --oauth the",
      "authorization URL is printed to stderr (a local browser is attempted best-effort) and the",
      "redirect is received on a loopback port; the credential is used for the one listing, not stored.",
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

async function runListTools(rest: string[]): Promise<never> {
  let parsed: ReturnType<typeof parseListToolsArguments>;
  try {
    parsed = parseListToolsArguments(rest);
  } catch (error) {
    bail(error instanceof Error ? error.message : String(error), 2);
  }
  try {
    const listing = await performListTools(parsed, callbacks);
    // stdout is a PIPE when the Haskell `katari` binary spawns us, so `write` is asynchronous: a large
    // listing (Notion's runs past the ~64 KB pipe buffer) is still draining when an immediate
    // `process.exit` would truncate it — the reader then parses a half-written JSON string. Await the
    // write's flush before exiting. `process.exit` is still needed: the MCP SDK leaves a keep-alive
    // socket that would otherwise hold the event loop open past the listing.
    await new Promise<void>((resolve) => {
      process.stdout.write(`${JSON.stringify(listing)}\n`, () => resolve());
    });
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
    case "list-tools":
      await runListTools(rest);
      break;
    default:
      bail(`unknown subcommand: ${subcommand ?? ""} (list-tools is the only verb)`, 2);
  }
}

await main();
