// Real end-to-end: each samples/ project is applied + run through the
// Haskell `katari` CLI. The runtime is the api-server test harness
// bound to an ephemeral port; the binary speaks HTTP to it just like
// it would in production.
//
// Skipped when the katari binary is not available — local runs need
// `stack install katari` first. CI sets KATARI_BIN explicitly.

import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { resolve } from "node:path";
import { startHttpHarness } from "@katari-lang/api-server/tests/helpers.js";
import type { MockAgentHandler, RawValue } from "@katari-lang/runtime";
import { encryptSecret, resetKeyCacheForTesting } from "@katari-lang/runtime";
import { afterEach, beforeAll, describe, expect, it } from "vitest";

// Crypto key for secret-bearing samples. Set before any harness boots so
// that the api-server side can encrypt / decrypt env entries; the key
// itself is throw-away (= per-test-run random).
beforeAll(() => {
  if (process.env.KATARI_SECRET_KEY === undefined || process.env.KATARI_SECRET_KEY === "") {
    process.env.KATARI_SECRET_KEY = randomBytes(32).toString("hex");
  }
  resetKeyCacheForTesting();
});

const SAMPLES_ROOT = resolve(__dirname, "../samples");

type HttpHarness = Awaited<ReturnType<typeof startHttpHarness>>;

let active: HttpHarness | null = null;
afterEach(async () => {
  if (active !== null) {
    await active.shutdown();
    active = null;
  }
});

function findKatariBinary(): string | null {
  const explicit = process.env.KATARI_BIN;
  if (explicit !== undefined && explicit.length > 0) {
    const r = spawnSync(explicit, ["--help"], { stdio: "ignore" });
    if (r.status === 0 || r.status === 1) return explicit;
  }
  // Prefer the freshly-BUILT binary (`stack build` updates this in-place) over
  // any `katari` on PATH — a `stack install`ed PATH binary goes stale the moment
  // you `stack build`, which silently ran the OLD CLI against a NEW runtime. So
  // `stack build katari` alone is enough; no `stack install` needed.
  const stackPath = spawnSync("stack", ["path", "--local-install-root"], {
    encoding: "utf8",
    cwd: resolve(__dirname, "../.."),
  });
  if (stackPath.status === 0) {
    const root = stackPath.stdout.trim();
    const candidate = `${root}/bin/katari`;
    const probe = spawnSync(candidate, ["--help"], { stdio: "ignore" });
    if (probe.status === 0 || probe.status === 1) return candidate;
  }
  // Fallback: a `katari` on PATH (CI, or an explicit install).
  const onPath = spawnSync("katari", ["--help"], { stdio: "ignore" });
  if (onPath.status === 0 || onPath.status === 1) return "katari";
  return null;
}

function findBundleScript(): string {
  // The bundler script lives alongside katari-bundle's compiled output.
  return resolve(__dirname, "../../typescript/packages/katari-bundle/dist/cli.js");
}

const RESOLVED_KATARI = findKatariBinary();
const RUN_E2E = RESOLVED_KATARI !== null;
const itE2E = RUN_E2E ? it : it.skip;

// Convention: every sample lives at `e2e/samples/<NN>-<name>` and its
// Katari package name is `<name>` with hyphens turned into underscores.
function packageNameFromSampleDir(sampleDir: string): string {
  return sampleDir.replace(/^\d+-/, "").replace(/-/g, "_");
}

interface SpawnResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runKatari(args: string[], cwd: string): Promise<SpawnResult> {
  // Async spawn (not spawnSync) so the in-process Hono harness on the
  // same event loop can answer the binary's HTTP requests while we
  // wait for it to exit.
  return new Promise((resolveP, rejectP) => {
    const child = spawn(RESOLVED_KATARI!, args, {
      cwd,
      env: {
        ...process.env,
        KATARI_BUNDLE_BIN: findBundleScript(),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", rejectP);
    child.on("close", (status) => resolveP({ status, stdout, stderr }));
  });
}

async function applyAndRun(
  _projectName: string,
  sampleDir: string,
  opts?: {
    handlers?: Record<string, MockAgentHandler>;
    /** Env entries seeded into the harness's store before `katari run`.
     * Secret entries should pass `isSecret: true` along with the
     * plaintext; this helper encrypts via 'encryptSecret' to match
     * what the live HTTP `PUT /env` route does. */
    envEntries?: { key: string; value: string; isSecret: boolean }[];
  },
): Promise<RawValue> {
  const harness = await startHttpHarness();
  active = harness;
  for (const [qname, fn] of Object.entries(opts?.handlers ?? {})) {
    harness.setHandler(qname, fn);
  }
  const sampleRoot = resolve(SAMPLES_ROOT, sampleDir);
  const pkg = packageNameFromSampleDir(sampleDir);

  // 1. katari apply
  const applyR = await runKatari(["apply", "--api-url", harness.url], sampleRoot);
  if (applyR.status !== 0) {
    throw new Error(
      `katari apply failed (status=${applyR.status})\nstdout:\n${applyR.stdout}\nstderr:\n${applyR.stderr}`,
    );
  }

  // Seed env AFTER apply: env is per-project (keyed by project id), and the
  // project only exists once `apply` has created it. Resolve it by the package
  // name (= the project name the run targets via `--project`).
  if ((opts?.envEntries ?? []).length > 0) {
    const project = await harness.storage.projects.getByName(pkg);
    if (project === null) {
      throw new Error(`env seed: project '${pkg}' not found after apply`);
    }
    for (const entry of opts?.envEntries ?? []) {
      await harness.storage.envEntries.upsert({
        projectId: project.id,
        key: entry.key,
        value: entry.isSecret ? encryptSecret(entry.value) : entry.value,
        isSecret: entry.isSecret,
      });
    }
  }

  // 2. katari run --wait (samples take no args, so pass `{}`
  // explicitly — otherwise katari would drop into the interactive
  // schema prompt which can't read from this subprocess's closed
  // stdin.)
  const runR = await runKatari(
    ["run", `${pkg}.main`, "--api-url", harness.url, "--project", pkg, "--args", "{}", "--wait"],
    sampleRoot,
  );
  if (runR.status !== 0) {
    throw new Error(
      `katari run failed (status=${runR.status})\nstdout:\n${runR.stdout}\nstderr:\n${runR.stderr}`,
    );
  }
  const trimmed = runR.stdout.trim();
  if (trimmed === "") {
    throw new Error(`katari run produced no result stdout (stderr: ${runR.stderr})`);
  }
  return JSON.parse(trimmed) as RawValue;
}

describe("samples/ end-to-end (apply → run → verify)", () => {
  if (!RUN_E2E) {
    it.skip("katari binary not available — set KATARI_BIN or run `stack install katari`", () => {});
    return;
  }

  itE2E("01-hello: main() returns 'hello, world'", async () => {
    const result = await applyAndRun("hello", "01-hello");
    expect(result).toBe("hello, world");
  });

  itE2E("02-arithmetic: main() returns 5", async () => {
    const result = await applyAndRun("arithmetic", "02-arithmetic");
    expect(result).toBe(5);
  });

  itE2E("03-data-and-match: main() returns 7", async () => {
    const result = await applyAndRun("data-and-match", "03-data-and-match");
    expect(result).toBe(7);
  });

  itE2E("04-agent-value: main() returns 42 (exercises agentLiteral)", async () => {
    const result = await applyAndRun("agent-value", "04-agent-value");
    expect(result).toBe(42);
  });

  itE2E("05-control-flow: main() returns 'positive'", async () => {
    const result = await applyAndRun("control-flow", "05-control-flow");
    expect(result).toBe("positive");
  });

  itE2E("06-for-and-fstring: main() returns 'sum = 6'", async () => {
    const result = await applyAndRun("for-and-fstring", "06-for-and-fstring");
    expect(result).toBe("sum = 6");
  });

  itE2E("07-abs-and-mod: manhattan with negative literals + mod = 11", async () => {
    const result = await applyAndRun("abs-and-mod", "07-abs-and-mod");
    expect(result).toBe(11);
  });

  itE2E(
    "08-metadata: get_metadata yields the agent's qname + the closure's dispatch id",
    async () => {
      const result = await applyAndRun("metadata", "08-metadata");
      // A top-level agent's id is its qname; a closure's id is its dispatch
      // handle `closureref:<ref id>` (identical to the closure value's wire form
      // + delegate target). The ref id is a per-occurrence uuid, so assert the
      // shape, not the exact value.
      expect(typeof result).toBe("string");
      const parts = (result as string).split("|");
      expect(parts.slice(0, 3)).toEqual(["add_them", "metadata.add_them", "local_bar"]);
      expect(parts[3]).toMatch(/^closureref:[0-9a-f-]{36}$/);
    },
  );

  itE2E("09-req-handler: three ticks under a stateful handler sum to 6", async () => {
    const result = await applyAndRun("req-handler", "09-req-handler");
    expect(result).toBe(6);
  });

  itE2E(
    "10-tuple-pattern: (integer, string) tuple destructured via match returns '42 with hello'",
    async () => {
      const result = await applyAndRun("tuple-pattern", "10-tuple-pattern");
      expect(result).toBe("42 with hello");
    },
  );

  itE2E("11-ext-agent: extGreet returns 'hello, ext' via the MockSidecar registry", async () => {
    const result = await applyAndRun("ext-agent", "11-ext-agent", {
      handlers: {
        "ext_agent.extGreet": async ({ args }) => `hello, ${args.name as string}`,
      },
    });
    expect(result).toBe("hello, ext");
  });

  // 12-ext-cron exercises ipcChildDelegate which the MockSidecar
  // intentionally does not route. The full round-trip is exercised in
  // subprocess-sidecar.integration.test.ts against a real bundle.

  itE2E(
    "13-throw-catch: explicit throw caught by handle scope returns 'caught: kaboom!'",
    async () => {
      const result = await applyAndRun("throw-catch", "13-throw-catch");
      expect(result).toBe("caught: kaboom!");
    },
  );

  itE2E(
    "14-runtime-error: prim div-by-zero caught by handle scope returns 'engine threw: prim div: division by zero'",
    async () => {
      const result = await applyAndRun("runtime-error", "14-runtime-error");
      expect(result).toBe("engine threw: prim div: division by zero");
    },
  );

  itE2E(
    "15-ext-throw-catch: ext handler throw caught by handle scope returns 'ext threw: kaboom from JS'",
    async () => {
      const result = await applyAndRun("ext-throw-catch", "15-ext-throw-catch", {
        handlers: {
          "ext_throw_catch.boomExt": async () => {
            throw new Error("kaboom from JS");
          },
        },
      });
      expect(result).toBe("ext threw: kaboom from JS");
    },
  );

  itE2E("16-multi-package: dep `list_utils` doubles 6 to 12 across packages", async () => {
    const result = await applyAndRun("multi-package", "16-multi-package");
    expect(result).toBe(12);
  });

  itE2E(
    "17-secret-mock-ai: get_secret_env → http_request roundtrip preserves the secret value across the FFI boundary",
    async () => {
      const result = await applyAndRun("secret-mock-ai", "17-secret-mock-ai", {
        envEntries: [{ key: "MOCK_KEY", value: "test_token_123", isSecret: true }],
        handlers: {
          "secret_mock_ai.http_request": async ({ args }) => {
            const url = args["url"] as string;
            const auth = args["auth"] as { $secret: string };
            return `GET ${url} (auth=${auth.$secret})`;
          },
        },
      });
      expect(result).toBe("GET https://example.com/echo (auth=test_token_123)");
    },
  );

  itE2E(
    "19-record-literal: { name = ..., age = ... } + record_set + record_size returns 3",
    async () => {
      const result = await applyAndRun("record-literal", "19-record-literal");
      expect(result).toBe(3);
    },
  );

  itE2E(
    "20-pattern-narrowing: integer/string/boolean/record type guards + record pattern narrow `unknown`",
    async () => {
      const result = await applyAndRun("pattern-narrowing", "20-pattern-narrowing");
      expect(result).toBe("int:42 | str:hello | bool:true | user:alice | other");
    },
  );

  itE2E(
    "21-json: json_parse + record pattern + json_stringify round-trip a JSON object",
    async () => {
      const result = await applyAndRun("json", "21-json");
      expect(result).toBe('name=alice; echo={"name":"alice","age":30}');
    },
  );

  itE2E(
    "22-call-agent: dynamic dispatch + schema validation surfaces call_agent_error on bad args",
    async () => {
      const result = await applyAndRun("call_agent", "22-call-agent");
      expect(result).toMatch(/^ok=hello, alice; bad=err: /);
    },
  );

  itE2E(
    "23-call-closure: dispatch a local closure via its get_metadata id (closureref round-trip)",
    async () => {
      // name → metadata → `closureref:<id>` → call_agent resolves the closure
      // blob, validates args, and runs it: the AI-tool-calling round-trip.
      const result = await applyAndRun("call_closure", "23-call-closure");
      expect(result).toBe("hi bob");
    },
  );
});
