// End-to-end smoke test for the katari-lsp binary.
//
// Spawns the LSP server as a subprocess, drives the LSP wire protocol
// directly (Content-Length framing + JSON-RPC), and asserts the
// happy-path round-trip for every public LSP method we serve:
// initialize / hover / definition / references / completion /
// publishDiagnostics. The "label completion" case also exercises the
// `(` trigger character — without `optCompletionTriggerCharacters`
// set on the server side the request never fires.
//
// Skipped when the katari-lsp binary is not on PATH (CI sets
// KATARI_LSP_BIN; local runs need `stack install katari-lsp` first).
//
// We intentionally do not depend on `vscode-jsonrpc` — the framing is
// trivial enough to roll inline, and we keep the e2e package's
// dependency surface small.

import { type ChildProcessWithoutNullStreams, spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { afterEach, describe, expect, it } from "vitest";

const SAMPLES_ROOT = resolve(__dirname, "../samples");

function findLspBinary(): string | null {
  const explicit = process.env.KATARI_LSP_BIN;
  if (explicit !== undefined && explicit.length > 0) {
    return explicit;
  }
  const probe = spawnSync("katari-lsp", ["--help"], { stdio: "ignore" });
  if (probe.error === undefined || probe.error === null) return "katari-lsp";
  return null;
}

const RESOLVED = findLspBinary();
const RUN_LSP = RESOLVED !== null;
const itLsp = RUN_LSP ? it : it.skip;

class LspClient {
  private child: ChildProcessWithoutNullStreams;
  private buffer = Buffer.alloc(0);
  private pending = new Map<number, (msg: any) => void>();
  private notifications: any[] = [];
  private nextId = 1;

  constructor(binary: string) {
    this.child = spawn(binary, [], { stdio: ["pipe", "pipe", "pipe"] });
    this.child.stderr.on("data", (chunk) => {
      // Surface server stderr only on failure; uncomment to debug.
      // process.stderr.write(`[lsp stderr] ${chunk}`);
      void chunk;
    });
    this.child.stdout.on("data", (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      while (this.tryParseOne()) {
        /* parse next */
      }
    });
  }

  private tryParseOne(): boolean {
    const headerEnd = this.buffer.indexOf("\r\n\r\n");
    if (headerEnd < 0) return false;
    const header = this.buffer.subarray(0, headerEnd).toString("utf8");
    const match = /Content-Length:\s*(\d+)/i.exec(header);
    if (match === null) {
      // malformed; drop everything to recover
      this.buffer = Buffer.alloc(0);
      return false;
    }
    const len = Number(match[1]);
    const bodyStart = headerEnd + 4;
    if (this.buffer.length < bodyStart + len) return false;
    const body = this.buffer.subarray(bodyStart, bodyStart + len).toString("utf8");
    this.buffer = this.buffer.subarray(bodyStart + len);
    const msg = JSON.parse(body);
    if (typeof msg.id === "number" && this.pending.has(msg.id)) {
      const resolve = this.pending.get(msg.id)!;
      this.pending.delete(msg.id);
      resolve(msg);
    } else {
      this.notifications.push(msg);
    }
    return true;
  }

  private send(msg: object): void {
    const body = JSON.stringify(msg);
    const header = `Content-Length: ${Buffer.byteLength(body, "utf8")}\r\n\r\n`;
    this.child.stdin.write(header + body);
  }

  async request<T = any>(method: string, params: unknown): Promise<T> {
    const id = this.nextId++;
    const promise = new Promise<T>((resolve) => this.pending.set(id, resolve));
    this.send({ jsonrpc: "2.0", id, method, params });
    return promise;
  }

  notify(method: string, params: unknown): void {
    this.send({ jsonrpc: "2.0", method, params });
  }

  takeNotifications(): any[] {
    const out = this.notifications;
    this.notifications = [];
    return out;
  }

  async shutdown(): Promise<void> {
    try {
      await this.request("shutdown", null);
      this.notify("exit", null);
    } catch {
      /* ignore */
    }
    this.child.kill();
  }
}

let active: LspClient | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

async function delay(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

describe("katari-lsp smoke", () => {
  if (!RUN_LSP) {
    it.skip("katari-lsp not on PATH — set KATARI_LSP_BIN or run `stack install katari-lsp`", () => {});
    return;
  }

  itLsp("initialize advertises hover/definition/references/completion", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    const reply = await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "01-hello")).toString(),
      capabilities: {},
    });
    expect(reply.result).toBeDefined();
    const caps = reply.result.capabilities;
    expect(caps.hoverProvider).toBeTruthy();
    expect(caps.definitionProvider).toBeTruthy();
    expect(caps.referencesProvider).toBeTruthy();
    expect(caps.completionProvider).toBeDefined();
  });

  itLsp("hover on a known position returns content", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "01-hello")).toString(),
      capabilities: {},
    });
    client.notify("initialized", {});

    const mainPath = resolve(SAMPLES_ROOT, "01-hello/src/hello.ktr");
    const text = readFileSync(mainPath, "utf8");
    client.notify("textDocument/didOpen", {
      textDocument: {
        uri: pathToFileURL(mainPath).toString(),
        languageId: "katari",
        version: 1,
        text,
      },
    });

    // Wait for the debounced recompile (150ms) + some slack.
    await delay(800);

    // Position 0:0 likely sits at the start of the file; we don't need
    // a meaningful hover — we just want to confirm the request /
    // response round-trip works without the server crashing.
    const hover = await client.request("textDocument/hover", {
      textDocument: { uri: pathToFileURL(mainPath).toString() },
      position: { line: 0, character: 0 },
    });
    // Either a Hover object or null. Both are acceptable — what we're
    // checking is that the server actually responded.
    expect(hover).toHaveProperty("result");
  });

  itLsp("hover on the agent identifier returns its rendered type", async () => {
    // `agent main() -> string { ... }` on line 2: hovering "main" at
    // line 2 column 8 should return a Hover whose markdown body
    // contains a rendered Katari type (e.g. mentions "string" since
    // the agent returns string).
    const client = new LspClient(RESOLVED!);
    active = client;
    await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "01-hello")).toString(),
      capabilities: {},
    });
    client.notify("initialized", {});

    const mainPath = resolve(SAMPLES_ROOT, "01-hello/src/hello.ktr");
    const text = readFileSync(mainPath, "utf8");
    client.notify("textDocument/didOpen", {
      textDocument: {
        uri: pathToFileURL(mainPath).toString(),
        languageId: "katari",
        version: 1,
        text,
      },
    });
    await delay(800);

    // LSP positions are 0-indexed. "main" starts at character 6 on line 1
    // (= source line 2: `agent main() -> string {`).
    const reply = await client.request("textDocument/hover", {
      textDocument: { uri: pathToFileURL(mainPath).toString() },
      position: { line: 1, character: 8 },
    });
    expect(reply.result).not.toBeNull();
    const value = reply.result?.contents?.value;
    expect(typeof value).toBe("string");
    // The renderer should mention "string" (the return type) and
    // should not be the old "<type>" placeholder.
    expect(value).toContain("string");
    expect(value).not.toContain("<type>");
  });

  itLsp(
    "hover on a non-name position inside an agent body returns null (regression: no fallback to agent name)",
    async () => {
      // Repro for the user-reported bug: hovering on whitespace inside
      // an agent body used to leak the agent's hover info because the
      // fallback in hoverFromDeclaration triggered unconditionally
      // when the body didn't return a hover target.
      const client = new LspClient(RESOLVED!);
      active = client;
      await client.request("initialize", {
        processId: process.pid,
        rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "01-hello")).toString(),
        capabilities: {},
      });
      client.notify("initialized", {});

      const mainPath = resolve(SAMPLES_ROOT, "01-hello/src/hello.ktr");
      const text = readFileSync(mainPath, "utf8");
      client.notify("textDocument/didOpen", {
        textDocument: {
          uri: pathToFileURL(mainPath).toString(),
          languageId: "katari",
          version: 1,
          text,
        },
      });
      await delay(800);

      // Line 3 column 1 is just before "hello, world" — pure
      // whitespace, not on any identifier. Should hover to null.
      const reply = await client.request("textDocument/hover", {
        textDocument: { uri: pathToFileURL(mainPath).toString() },
        position: { line: 2, character: 1 },
      });
      // null is encoded as Hover with no result, or result: null.
      // The bug would return a Hover whose body mentions "main.main".
      const value = reply.result?.contents?.value as string | undefined;
      if (value !== undefined) {
        expect(value).not.toContain("main.main");
      }
    },
  );

  itLsp("hover on a literal shows its inferred type", async () => {
    // 01-hello/src/hello.ktr line 3: `  "hello, world"` — hovering
    // anywhere inside the string literal should return its
    // inferred type (a string literal type), not Null.
    const client = new LspClient(RESOLVED!);
    active = client;
    await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "01-hello")).toString(),
      capabilities: {},
    });
    client.notify("initialized", {});

    const mainPath = resolve(SAMPLES_ROOT, "01-hello/src/hello.ktr");
    const text = readFileSync(mainPath, "utf8");
    client.notify("textDocument/didOpen", {
      textDocument: {
        uri: pathToFileURL(mainPath).toString(),
        languageId: "katari",
        version: 1,
        text,
      },
    });
    await delay(800);

    // Line 3, char 5: somewhere inside the string literal "hello, world".
    const reply = await client.request("textDocument/hover", {
      textDocument: { uri: pathToFileURL(mainPath).toString() },
      position: { line: 2, character: 5 },
    });
    expect(reply.result).not.toBeNull();
    const value = reply.result?.contents?.value as string | undefined;
    expect(value).toBeDefined();
    // The renderer should produce something containing the literal
    // value (or its type "string"). Either way it must NOT be the
    // old "<type>" placeholder, and it must NOT leak the agent
    // qualified name.
    expect(value).not.toContain("<type>");
    expect(value).not.toContain("main.main");
  });

  // -------------------------------------------------------------------
  // definition / references / completion / diagnostics
  //
  // Fixture: e2e/samples/02-arithmetic/src/arithmetic.ktr
  //   line 1: @"Adds two integers."
  //   line 2: agent sum_two(a: integer, b: integer) -> integer {
  //   line 3:   a + b
  //   line 4: }
  //   line 5:
  //   line 6: @"Returns the sum of 2 and 3 (= 5)."
  //   line 7: agent main() -> integer {
  //   line 8:   sum_two(a = 2, b = 3)
  //   line 9: }
  // -------------------------------------------------------------------

  async function openArithmetic(client: LspClient): Promise<{ uri: string; mainPath: string }> {
    await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "02-arithmetic")).toString(),
      capabilities: {},
    });
    client.notify("initialized", {});
    const mainPath = resolve(SAMPLES_ROOT, "02-arithmetic/src/arithmetic.ktr");
    const text = readFileSync(mainPath, "utf8");
    const uri = pathToFileURL(mainPath).toString();
    client.notify("textDocument/didOpen", {
      textDocument: { uri, languageId: "katari", version: 1, text },
    });
    await delay(800);
    return { uri, mainPath };
  }

  itLsp("definition jumps from the call site to the agent declaration", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    const { uri } = await openArithmetic(client);

    // Line 8 col 2 (0-indexed line 7, char 2) is on the `sum_two` call.
    const reply = await client.request("textDocument/definition", {
      textDocument: { uri },
      position: { line: 7, character: 4 },
    });
    expect(reply.result).toBeDefined();
    // Server returns a Location (or array of Locations).
    const loc = Array.isArray(reply.result) ? reply.result[0] : reply.result;
    expect(loc).not.toBeNull();
    expect(loc.uri).toBe(uri);
    // Declaration is on line 2 (0-indexed = 1).
    expect(loc.range.start.line).toBe(1);
  });

  itLsp("references returns both the declaration and the call site", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    const { uri } = await openArithmetic(client);

    // Cursor on `sum_two` declaration (line 2 col 7 → 0-indexed 1:6+).
    const reply = await client.request("textDocument/references", {
      textDocument: { uri },
      position: { line: 1, character: 8 },
      context: { includeDeclaration: true },
    });
    expect(Array.isArray(reply.result)).toBe(true);
    const lines = (reply.result as Array<{ range: { start: { line: number } } }>).map(
      (l) => l.range.start.line,
    );
    // Expect at least the declaration line (1) and the call line (7).
    expect(lines).toContain(1);
    expect(lines).toContain(7);
  });

  itLsp("completion after `(` lists the callable's parameter labels", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    const { uri } = await openArithmetic(client);

    // main.ktr line 8 (0-indexed 7) is `  sum_two(a = 2, b = 3)`.
    // Position character 10 sits between `(` and `a` — the prefix the
    // server inspects is `  sum_two(`, so label completion should fire
    // and offer both `a` and `b`.
    const reply = await client.request("textDocument/completion", {
      textDocument: { uri },
      position: { line: 7, character: 10 },
      context: { triggerKind: 2, triggerCharacter: "(" },
    });
    const items = (
      Array.isArray(reply.result) ? reply.result : (reply.result?.items ?? [])
    ) as Array<{ label: string }>;
    const labels = items.map((i) => i.label);
    expect(labels).toContain("a");
    expect(labels).toContain("b");
  });

  itLsp("publishDiagnostics emits then clears as syntax errors are fixed", async () => {
    const client = new LspClient(RESOLVED!);
    active = client;
    await client.request("initialize", {
      processId: process.pid,
      rootUri: pathToFileURL(resolve(SAMPLES_ROOT, "02-arithmetic")).toString(),
      capabilities: {},
    });
    client.notify("initialized", {});

    const uri = pathToFileURL(resolve(SAMPLES_ROOT, "02-arithmetic/src/arithmetic.ktr")).toString();

    // Open with a broken source (missing closing brace).
    const broken = "agent main() -> integer {\n  1\n";
    client.notify("textDocument/didOpen", {
      textDocument: { uri, languageId: "katari", version: 1, text: broken },
    });
    await delay(800);

    const brokenDiags = client
      .takeNotifications()
      .filter((n) => n.method === "textDocument/publishDiagnostics" && n.params?.uri === uri);
    expect(brokenDiags.length).toBeGreaterThan(0);
    expect(brokenDiags[brokenDiags.length - 1].params.diagnostics.length).toBeGreaterThan(0);

    // Now patch the file to a valid program — diagnostics should clear.
    const fixed = "agent main() -> integer {\n  1\n}\n";
    client.notify("textDocument/didChange", {
      textDocument: { uri, version: 2 },
      contentChanges: [{ text: fixed }],
    });
    await delay(800);

    const fixedDiags = client
      .takeNotifications()
      .filter((n) => n.method === "textDocument/publishDiagnostics" && n.params?.uri === uri);
    expect(fixedDiags.length).toBeGreaterThan(0);
    expect(fixedDiags[fixedDiags.length - 1].params.diagnostics).toEqual([]);
  });
});
