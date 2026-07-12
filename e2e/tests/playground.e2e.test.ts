// The smoke e2e: the one suite that exercises the REAL seams — .ktr source → the stack-built katari
// CLI (compile + bundle + deploy over HTTP) → the runtime server (postgres + s3mock) → runs, files,
// escalations, rollback, and a server restart. Unit suites cover each layer in isolation; this is the
// wire-compatibility net between the Haskell compiler's IR/schema output and the TypeScript runtime.
//
// Prerequisites (see e2e/README.md): docker (compose postgres + s3mock) and a `stack build` katari
// binary. The suite provisions its own database (`katari_e2e`) and bucket, so it never touches dev data.

import { type ChildProcess, execFile, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, expect, test } from "vitest";
import { z } from "zod";

const execFileAsync = promisify(execFile);

const REPO = fileURLToPath(new URL("../..", import.meta.url));
const PORT = 3517;
const URL_BASE = `http://127.0.0.1:${PORT}`;
const API = `${URL_BASE}/api/v1`;
const API_KEY = "e2e-api-key";
// The same fixed, throwaway at-rest key the runtime's own vitest config uses — not a real secret.
const SECRET_KEY = "r75FbGEeJdHhNknc0999YH3+Kzggi0MExVVFU9TSi7U=";
const DATABASE = "katari_e2e";
const BUCKET = "katari-e2e-blobs";
const S3 = "http://127.0.0.1:9090";
const PLAYGROUND = join(REPO, "examples/playground");

let katariBin = "";
let server: Server | null = null;
const scratch = mkdtempSync(join(tmpdir(), "katari-e2e-"));

// ─── helpers ────────────────────────────────────────────────────────────────────────────────────

/** Run a command to completion, throwing (with its output) on a non-zero exit. */
async function sh(
  command: string,
  args: string[],
  options: { cwd?: string; env?: Record<string, string | undefined> } = {},
): Promise<{ stdout: string; stderr: string }> {
  return execFileAsync(command, args, {
    cwd: options.cwd ?? REPO,
    env: { ...process.env, ...options.env },
    maxBuffer: 64 * 1024 * 1024,
  });
}

/** The environment every katari CLI call runs with: the runtime URL rides as `--url` per call, the
 *  bearer token and the workspace's own bundler come from here (overriding any stale shell value). */
const cliEnv = {
  KATARI_API_KEY: API_KEY,
  KATARI_BUNDLE_BIN: join(REPO, "typescript/bundle/dist/cli.mjs"),
};

/** Run the katari CLI against the suite's server; throws (with output) on a non-zero exit. */
function katari(args: string[]): Promise<{ stdout: string; stderr: string }> {
  return sh(katariBin, [...args, "--url", URL_BASE], { env: cliEnv });
}

/** Run the katari CLI expecting failure; resolves with the exit code (non-zero) instead of throwing. */
async function katariExpectingFailure(args: string[]): Promise<number> {
  try {
    await katari(args);
    return 0;
  } catch (error) {
    const code = (error as { code?: number }).code;
    return typeof code === "number" ? code : 1;
  }
}

/** GET an API resource with the suite's bearer token, unwrapping the `{ ok, data }` envelope. */
async function apiGet<T>(path: string): Promise<T> {
  const response = await fetch(`${API}${path}`, {
    headers: { Authorization: `Bearer ${API_KEY}` },
  });
  if (!response.ok) throw new Error(`GET ${path} -> ${response.status}`);
  const body = (await response.json()) as { ok: boolean; data: T };
  return body.data;
}

/** Poll until `probe` resolves truthy, or fail with `what` after the deadline. */
async function waitFor<T>(what: string, probe: () => Promise<T | undefined>, ms = 60_000): Promise<T> {
  const deadline = Date.now() + ms;
  for (;;) {
    const value = await probe().catch(() => undefined);
    if (value !== undefined && value !== false) return value;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}

interface Server {
  proc: ChildProcess;
  logs: string[];
  stop(): Promise<void>;
}

/** Boot the runtime server (tsx over src, so no build step) against the suite's database and bucket,
 *  and wait for its health endpoint. Its stdout/stderr lines are captured for log assertions. */
async function startServer(): Promise<Server> {
  const proc = spawn("pnpm", ["exec", "tsx", "src/bin.ts"], {
    cwd: join(REPO, "typescript/runtime"),
    env: {
      ...process.env,
      PORT: String(PORT),
      DATABASE_URL: `postgres://katari:katari@127.0.0.1:5432/${DATABASE}`,
      KATARI_API_KEY: API_KEY,
      KATARI_SECRET_KEY: SECRET_KEY,
      BLOB_S3_BUCKET: BUCKET,
      BLOB_S3_ENDPOINT: S3,
      BLOB_S3_FORCE_PATH_STYLE: "true",
      BLOB_S3_CREATE_BUCKET: "true",
      AWS_ACCESS_KEY_ID: "s3mock",
      AWS_SECRET_ACCESS_KEY: "s3mock",
    },
  });
  const logs: string[] = [];
  proc.stdout?.on("data", (chunk: Buffer) => logs.push(chunk.toString()));
  proc.stderr?.on("data", (chunk: Buffer) => logs.push(chunk.toString()));
  const stop = () =>
    new Promise<void>((resolve) => {
      proc.once("exit", () => resolve());
      proc.kill("SIGTERM");
    });
  await waitFor(
    "the server's health endpoint",
    async () => ((await fetch(`${API}/health`)).ok ? true : undefined),
    120_000,
  ).catch((error) => {
    proc.kill("SIGKILL");
    throw new Error(`${String(error)}\nserver output:\n${logs.join("")}`);
  });
  return { proc, logs, stop };
}

async function psql(statement: string): Promise<void> {
  await sh("docker", ["exec", "katari-postgres", "psql", "-U", "katari", "-d", "katari", "-c", statement]);
}

/** The playground project's id (the CLI creates the project on first `apply`). */
function playgroundId(): Promise<string> {
  return waitFor("the playground project", async () => {
    const projects = await apiGet<{ id: string; name: string }[]>("/projects");
    return projects.find((project) => project.name === "playground")?.id;
  });
}

// ─── suite lifecycle ────────────────────────────────────────────────────────────────────────────

beforeAll(async () => {
  // The real katari binary — this suite exists to test it, so refuse to run without one.
  const { stdout } = await sh("stack", ["path", "--local-install-root"]).catch(() => {
    throw new Error("no stack toolchain found; the e2e suite needs the real katari CLI (`stack build`)");
  });
  katariBin = join(stdout.trim(), "bin", "katari");
  readFileSync(katariBin); // fails clearly when the binary was never built

  // Infrastructure: the dev compose services (idempotent when already up; the dummies only satisfy
  // compose's interpolation of the app service, which is not started), and an isolated database.
  await sh("docker", ["compose", "up", "-d", "--wait", "postgres", "s3mock"], {
    env: { KATARI_API_KEY: "dummy", KATARI_SECRET_KEY: "dummy" },
  });
  await psql(`DROP DATABASE IF EXISTS ${DATABASE};`);
  await psql(`CREATE DATABASE ${DATABASE};`);

  // The sidecar bundler the CLI shells out to on `apply` (playground has FFI handlers).
  await sh("pnpm", ["--filter", "@katari-lang/bundle", "build"]);

  server = await startServer();
});

afterAll(async () => {
  await server?.stop();
  await psql(`DROP DATABASE IF EXISTS ${DATABASE};`).catch(() => {});
});

// ─── the flow (tests run in order; later ones build on earlier state) ──────────────────────────

let firstSnapshot = "";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

test("apply compiles, bundles, and deploys the playground", async () => {
  // The CLI writes results only to stdout (progress goes to stderr), so `apply`'s stdout is the bare
  // new snapshot id.
  const { stdout, stderr } = await katari(["apply", "-C", PLAYGROUND, "-m", "e2e first"]);
  firstSnapshot = stdout.trim();
  expect(firstSnapshot).toMatch(UUID);
  expect(stderr).toContain("Applied snapshot");
});

test("basics.main: data/match, for, parallel for, handlers, prelude", async () => {
  const { stdout, stderr } = await katari(["run", "basics.main", "--project", "playground"]);
  expect(stdout).toContain("ticks=[0,1,2]");
  expect(stdout).toContain("sum(squares(4))=30");
  // Partial application, value-checked end to end: doubles is a residual of scale, and decorated
  // omits a ?=-defaulted parameter so the callee's runtime default must fill it through the residual.
  expect(stdout).toContain("doubles=[3,42]");
  expect(stdout).toContain("decorated=>> hello!");
  // The wait loop tails the run's execution trace to stderr: the launch delegate and the final ack
  // must have printed as summary lines while stdout stayed result-only.
  expect(stderr).toContain("delegate api→core basics.main");
  expect(stderr).toContain("delegateAck core→api");
});

test("tools.main: schema derivation, typed JSON boundary, dynamic dispatch", async () => {
  const { stdout } = await katari(["run", "tools.main", "--project", "playground"]);
  expect(stdout).toContain("result=5");
});

test("webhook.main: a minted inbound URL serves validated deliveries, then deactivates", async () => {
  const { stdout } = await katari(["run", "webhook.main", "--project", "playground"]);
  // The subscriber POSTed {value:21} and {value:4} to its own minted URL; each delivery ran the
  // callback (doubling) and the response body came back as the result text.
  expect(stdout).toContain("delivered: 42 and 8");
});

test("mcp_demo.main: the built-in MCP client mints the server's tools as agents", async () => {
  // A real MCP server on a loopback port (stateless streamable HTTP: a fresh server + transport per
  // request), exposing one `add` tool. The playground program opens it with `use mcp.provide(url = ...)`,
  // reads each minted agent's metadata, and dispatches `add` through `reflection.call_agent` — all
  // inside the provide scope the tools are gated by.
  const readBody = (request: IncomingMessage): Promise<unknown> =>
    new Promise((resolve, reject) => {
      let raw = "";
      request.setEncoding("utf8");
      request.on("data", (chunk: string) => {
        raw += chunk;
      });
      request.on("end", () => {
        try {
          resolve(raw === "" ? undefined : JSON.parse(raw));
        } catch (error) {
          reject(error instanceof Error ? error : new Error(String(error)));
        }
      });
      request.on("error", reject);
    });
  const mcpHttp = createServer((request, response) => {
    void (async () => {
      const mcp = new McpServer({ name: "katari-e2e", version: "1.0.0" });
      mcp.registerTool(
        "add",
        { description: "Adds two integers.", inputSchema: { x: z.number(), y: z.number() } },
        ({ x, y }) => ({ content: [{ type: "text", text: String(x + y) }] }),
      );
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
      response.on("close", () => {
        void transport.close();
        void mcp.close();
      });
      await mcp.connect(transport);
      await transport.handleRequest(request, response, await readBody(request));
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => mcpHttp.listen(0, "127.0.0.1", resolve));
  try {
    const address = mcpHttp.address();
    if (address === null || typeof address === "string") throw new Error("expected a TCP address");
    const port = address.port;
    const { stdout } = await katari([
      "run",
      "mcp_demo.main",
      "--project",
      "playground",
      "--arg",
      JSON.stringify({ url: `http://127.0.0.1:${port}/mcp` }),
    ]);
    // The minted agent advertised the server-declared name, and the dynamic dispatch returned 19+23.
    expect(stdout).toContain("tools=add");
    expect(stdout).toContain("42");
  } finally {
    mcpHttp.closeAllConnections();
    await new Promise<void>((resolve) => {
      mcpHttp.close(() => resolve());
    });
  }
});

test("errors.main: typed throw caught, panic caught, missing-secret fallback", async () => {
  const { stdout } = await katari(["run", "errors.main", "--project", "playground"]);
  expect(stdout).toContain("7 is odd — no half");
  expect(stdout).toContain("half=6");
  expect(stdout).toContain("panic caught: division by zero");
  expect(stdout).toContain("no secret under playground.no_such_key");
});

test("time.main: durable now + sleep resolve through the built-in time reactor", async () => {
  // A ~1s durable sleep bracketed by two `time.now` readings — the result text is deterministic in its
  // prefix (the elapsed span is at least the sleep, but not asserted exactly).
  const { stdout } = await katari(["run", "time.main", "--project", "playground"]);
  expect(stdout).toContain("slept for");
}, 20_000);

test("ffi.main: sidecar values, blobs both directions, inner delegation, typed throws", async () => {
  const { stdout } = await katari([
    "run",
    "ffi.main",
    "--project",
    "playground",
    "--arg",
    '{"name":"world"}',
  ]);
  expect(stdout).toContain("Hello, world!");
  expect(stdout).toContain("bytes=13");
  expect(stdout).toContain("compute(20)=41");
  expect(stdout).toContain("fallback_port=8080");
});

test("a suspended run survives a server restart (boot reactivation), then completes", async () => {
  const projectId = await playgroundId();

  // Detach a run that suspends on two escalations (the parallel `consult` children). `--detach` prints
  // the bare run id to stdout (progress goes to stderr).
  const { stdout } = await katari(["run", "interactive.main", "--project", "playground", "--detach"]);
  const runId = stdout.trim();
  expect(runId).toMatch(UUID);
  await waitFor("both escalations to open", async () => {
    const open = await apiGet<{ id: string }[]>(`/projects/${projectId}/escalations`);
    return open.length === 2 ? open : undefined;
  });

  // Kill the server mid-run and boot a fresh one. The new process must resume the project ITSELF
  // (boot reactivation) — not lazily on the next touch.
  await server?.stop();
  server = await startServer();
  await waitFor("the boot-time project resume", async () =>
    server?.logs.some((line) => line.includes("resumed a project with in-flight runs"))
      ? true
      : undefined,
  );

  // The escalations survived the restart; answer both and the run completes.
  const open = await apiGet<{ id: string }[]>(`/projects/${projectId}/escalations`);
  expect(open).toHaveLength(2);
  for (const escalation of open) {
    await katari(["answer", "--project", "playground", escalation.id, "--value", '"measure twice"']);
  }
  const run = await waitFor("the run to complete", async () => {
    const row = await apiGet<{ state: string; result?: unknown }>(
      `/projects/${projectId}/runs/${runId}`,
    );
    return row.state === "done" ? row : undefined;
  });
  expect(JSON.stringify(run.result)).toContain("safety: measure twice");
  expect(JSON.stringify(run.result)).toContain("cost: measure twice");

  // The run's execution trace survived the restart too (the journal is append-only and outlives the
  // live routing): the launch delegate opens it, the answered questions appear as escalate/escalateAck
  // legs, the final delegateAck closes it — in strictly increasing production order, each event with a
  // printable summary.
  const trace = await apiGet<{
    state: string;
    events: { seq: number; kind: string; summary: string }[];
  }>(`/projects/${projectId}/runs/${runId}/events`);
  expect(trace.state).toBe("done");
  expect(trace.events.length).toBeGreaterThanOrEqual(6);
  expect(trace.events[0]?.kind).toBe("delegate");
  expect(trace.events.at(-1)?.kind).toBe("delegateAck");
  const kinds = trace.events.map((event) => event.kind);
  expect(kinds).toContain("escalate");
  expect(kinds).toContain("escalateAck");
  const seqs = trace.events.map((event) => event.seq);
  expect([...seqs].sort((left, right) => left - right)).toEqual(seqs);
  for (const event of trace.events) expect(event.summary.length).toBeGreaterThan(0);
});

test("file upload / download / delete roundtrip", async () => {
  const source = join(scratch, "upload.txt");
  writeFileSync(source, "hello katari e2e");
  const { stdout } = await katari(["file", "upload", source, "--project", "playground", "--quiet"]);
  const fileId = stdout.trim();
  expect(fileId).toMatch(UUID);

  // A subcommand-local option (`-o`) must precede the parent-level `--project`, so keep `--project`
  // after the subcommand's own flags (optparse does not intersperse the two).
  const downloaded = join(scratch, "download.txt");
  await katari(["file", "download", fileId, "-o", downloaded, "--project", "playground"]);
  expect(readFileSync(downloaded, "utf8")).toBe("hello katari e2e");

  await katari(["file", "delete", fileId, "--project", "playground"]);
  const code = await katariExpectingFailure([
    "file",
    "download",
    fileId,
    "-o",
    join(scratch, "gone.txt"),
    "--project",
    "playground",
  ]);
  expect(code).not.toBe(0);
});

test("rollback moves the head; new runs follow it", async () => {
  const projectId = await playgroundId();
  const { stdout } = await katari(["apply", "-C", PLAYGROUND, "-m", "e2e second"]);
  const secondSnapshot = stdout.trim();
  expect(secondSnapshot).toMatch(UUID);
  expect(secondSnapshot).not.toBe(firstSnapshot);
  const headAfterApply = await apiGet<{ id: string | null }>(`/projects/${projectId}/snapshots/head`);
  expect(headAfterApply.id).toBe(secondSnapshot);

  await katari(["project", "rollback", firstSnapshot, "--project", "playground"]);
  const headAfterRollback = await apiGet<{ id: string | null }>(
    `/projects/${projectId}/snapshots/head`,
  );
  expect(headAfterRollback.id).toBe(firstSnapshot);

  // A new run follows the rolled-back head.
  const { stdout: runOut } = await katari(["run", "basics.main", "--project", "playground"]);
  expect(runOut).toContain("sum(squares(4))=30");
});

test("project delete frees the blob bytes in the store", async () => {
  const projectId = await playgroundId();
  const source = join(scratch, "orphan-check.txt");
  writeFileSync(source, "bytes that must not orphan");
  const { stdout } = await katari(["file", "upload", source, "--project", "playground", "--quiet"]);
  const fileId = stdout.trim();

  // s3mock ignores auth, so the object is readable directly — the ground truth for the byte store.
  const objectUrl = `${S3}/${BUCKET}/${projectId}/${fileId}`;
  expect((await fetch(objectUrl)).status).toBe(200);

  await katari(["project", "remove", "playground", "--force"]);
  expect((await fetch(objectUrl)).status).toBe(404);
  const projects = await apiGet<{ name: string }[]>("/projects");
  expect(projects.find((project) => project.name === "playground")).toBeUndefined();
});
