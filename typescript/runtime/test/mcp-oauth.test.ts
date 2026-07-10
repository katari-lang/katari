// The mcp auth sum, end to end at the transport seam: descriptor decoding (both variants, and the
// malformed shapes that must fail as TYPED throws, never engine errors), the stored-credential
// provider (token read, refresh write-back through the store, the interactive step refusing as the
// typed auth failure), and the two live paths over a real loopback MCP server — a `headers` descriptor
// riding its values as request headers, an `oauth` descriptor injecting the stored bearer token via
// the SDK's `authProvider`. What is NOT tested here: a real IdP round-trip (authorization-code + PKCE
// needs a browser; the interactive flow lives in `katari mcp login` and is exercised by hand).

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import type { Json } from "@katari-lang/types";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import {
  decodeMcpOAuthCredential,
  McpAuthError,
  type McpCredentialStore,
  mcpOAuthEnvKey,
  type McpOAuthCredential,
  StoredMcpOAuthProvider,
} from "../src/runtime/external/mcp-oauth.js";
import {
  type McpCompletion,
  type McpTransport,
  SdkMcpTransport,
} from "../src/runtime/external/mcp-transport.js";
import type { DelegationId } from "../src/runtime/ids.js";

const CREDENTIAL: McpOAuthCredential = {
  tokens: { access_token: "token-123", token_type: "Bearer", refresh_token: "refresh-123" },
  clientInformation: { client_id: "client-123" },
  resourceUrl: "https://mcp.example.test/mcp",
};

/** An in-memory credential store: what the facade's env-backed store does, minus the database. Each stored
 *  credential carries a monotonic generation (the facade uses a content hash); `save` is a compare-and-set
 *  against it, and `replace` simulates an out-of-band `katari mcp login` overwriting the credential. */
function memoryStore(seed: Record<string, McpOAuthCredential> = {}): McpCredentialStore & {
  saved: Array<{ name: string; credential: McpOAuthCredential }>;
  replace: (name: string, credential: McpOAuthCredential) => void;
} {
  const entries = new Map<string, { credential: McpOAuthCredential; generation: number }>();
  let sequence = 0;
  for (const [name, credential] of Object.entries(seed)) {
    sequence += 1;
    entries.set(name, { credential, generation: sequence });
  }
  const saved: Array<{ name: string; credential: McpOAuthCredential }> = [];
  return {
    saved,
    async load(name) {
      const entry = entries.get(name);
      return entry === undefined
        ? null
        : { credential: entry.credential, generation: String(entry.generation) };
    },
    async save(name, credential, expectedGeneration) {
      const entry = entries.get(name);
      // A stale generation (the credential was replaced since it was read — a re-login) refuses the write.
      if (entry !== undefined && String(entry.generation) !== expectedGeneration) return;
      sequence += 1;
      entries.set(name, { credential, generation: sequence });
      saved.push({ name, credential });
    },
    replace(name, credential) {
      sequence += 1;
      entries.set(name, { credential, generation: sequence });
    },
  };
}

/** Queue the transport's completions so a test can await them one by one. */
function completionQueue(transport: McpTransport): () => Promise<McpCompletion> {
  const pending: McpCompletion[] = [];
  const waiters: Array<(completion: McpCompletion) => void> = [];
  transport.onComplete((completion) => {
    const waiter = waiters.shift();
    if (waiter !== undefined) waiter(completion);
    else pending.push(completion);
  });
  return () => {
    const ready = pending.shift();
    if (ready !== undefined) return Promise.resolve(ready);
    return new Promise((resolve) => waiters.push(resolve));
  };
}

/** Assert a completion is the typed throw of `ctor` and return its message for content checks. */
function typedThrowMessage(completion: McpCompletion, ctor: string): string {
  if (completion.outcome.kind !== "throw") {
    throw new Error(`expected a typed throw, got ${completion.outcome.kind}`);
  }
  const error = completion.outcome.error;
  if (error === null || typeof error !== "object" || Array.isArray(error)) {
    throw new Error("expected a $constructor-tagged error payload");
  }
  expect(error.$constructor).toBe(ctor);
  const value = error.value;
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("expected the error payload to carry its fields");
  }
  return typeof value.message === "string" ? value.message : "";
}

let nextDelegation = 0;
function delegation(): DelegationId {
  nextDelegation += 1;
  return `delegation-mcp-oauth-${nextDelegation}` as DelegationId;
}

/** The `headers` variant's wire form (what `mcp.headers(values = ...)` lowers to, revealed). */
function headersAuth(values: Record<string, string>): Json {
  return { $constructor: "prelude.mcp.headers", value: { values } };
}

/** The `oauth` variant's wire form (what `mcp.oauth(name = ...)` lowers to). */
function oauthAuth(name: string): Json {
  return { $constructor: "prelude.mcp.oauth", value: { name } };
}

describe("mcpOAuthEnvKey", () => {
  test("reserves the dotted mcp.oauth namespace", () => {
    expect(mcpOAuthEnvKey("github")).toBe("mcp.oauth.github");
  });
});

describe("decodeMcpOAuthCredential", () => {
  test("round-trips the blob `katari mcp login` emits", () => {
    const decoded = decodeMcpOAuthCredential("github", JSON.stringify(CREDENTIAL));
    expect(decoded.tokens.access_token).toBe("token-123");
    expect(decoded.tokens.refresh_token).toBe("refresh-123");
    expect(decoded.clientInformation.client_id).toBe("client-123");
    expect(decoded.resourceUrl).toBe("https://mcp.example.test/mcp");
  });

  test("keeps the client secret a confidential client refreshes with", () => {
    const decoded = decodeMcpOAuthCredential(
      "github",
      JSON.stringify({
        ...CREDENTIAL,
        clientInformation: { client_id: "client-123", client_secret: "secret-123" },
      }),
    );
    expect(decoded.clientInformation.client_secret).toBe("secret-123");
  });

  test.each([
    ["not JSON at all", "not-json"],
    ["a non-object", JSON.stringify(["array"])],
    ["missing tokens", JSON.stringify({ ...CREDENTIAL, tokens: undefined })],
    [
      "missing client information",
      JSON.stringify({ ...CREDENTIAL, clientInformation: undefined }),
    ],
    ["missing the resource url", JSON.stringify({ ...CREDENTIAL, resourceUrl: undefined })],
  ])("an unreadable blob (%s) is the typed auth failure naming the fix", (_label, raw) => {
    expect(() => decodeMcpOAuthCredential("github", raw)).toThrowError(McpAuthError);
    expect(() => decodeMcpOAuthCredential("github", raw)).toThrowError(/katari mcp login/);
  });
});

describe("StoredMcpOAuthProvider", () => {
  test("serves the stored tokens and writes refreshed ones back through the store", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    const provider = new StoredMcpOAuthProvider("github", store);
    expect((await provider.tokens()).access_token).toBe("token-123");

    await provider.saveTokens({ access_token: "token-456", token_type: "Bearer" });
    // The rotated set is durable (a refresh token is often single-use) and immediately served.
    expect(store.saved).toHaveLength(1);
    expect(store.saved[0]?.credential.tokens.access_token).toBe("token-456");
    expect(store.saved[0]?.credential.clientInformation.client_id).toBe("client-123");
    expect((await provider.tokens()).access_token).toBe("token-456");
  });

  test("reads through on each use, so a warm provider serves a re-login's replaced credential", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    const provider = new StoredMcpOAuthProvider("github", store);
    expect((await provider.tokens()).access_token).toBe("token-123");
    // A human re-runs `katari mcp login`, replacing the stored credential out of band.
    store.replace("github", {
      ...CREDENTIAL,
      tokens: { access_token: "relogin-999", token_type: "Bearer", refresh_token: "relogin-r" },
    });
    // The warm provider does NOT keep serving the stale token — it reads through on the next use.
    expect((await provider.tokens()).access_token).toBe("relogin-999");
  });

  test("a refresh write-back refuses to clobber a credential a re-login replaced under it", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    const provider = new StoredMcpOAuthProvider("github", store);
    // The provider reads the credential (the read that drives an about-to-happen refresh)…
    expect((await provider.tokens()).access_token).toBe("token-123");
    // …then a re-login replaces it before that refresh's write-back lands.
    store.replace("github", {
      ...CREDENTIAL,
      tokens: { access_token: "relogin-999", token_type: "Bearer", refresh_token: "relogin-r" },
    });
    // The stale write-back is refused (compare-and-set on the generation it read), so nothing is saved…
    await provider.saveTokens({ access_token: "stale-refresh", token_type: "Bearer" });
    expect(store.saved).toHaveLength(0);
    // …and the newer credential stands.
    expect((await provider.tokens()).access_token).toBe("relogin-999");
  });

  test("the interactive steps refuse as the typed auth failure (the runtime cannot log in)", () => {
    const provider = new StoredMcpOAuthProvider("github", memoryStore());
    expect(() => provider.redirectToAuthorization()).toThrowError(McpAuthError);
    expect(() => provider.redirectToAuthorization()).toThrowError(/katari mcp login/);
    expect(() => provider.codeVerifier()).toThrowError(McpAuthError);
    expect(() => provider.saveCodeVerifier()).toThrowError(McpAuthError);
  });
});

describe("SdkMcpTransport descriptor decoding", () => {
  test.each<[string, Json | null]>([
    ["a null descriptor", null],
    ["a descriptor with no url", { auth: headersAuth({}) }],
    ["a descriptor with no auth", { url: "http://127.0.0.1:1/mcp" }],
    [
      "an auth value of an unknown constructor",
      { url: "http://127.0.0.1:1/mcp", auth: { $constructor: "prelude.mcp.unknown", value: {} } },
    ],
    [
      "an oauth value with no credential name",
      { url: "http://127.0.0.1:1/mcp", auth: { $constructor: "prelude.mcp.oauth", value: {} } },
    ],
  ])("%s fails as the typed server_error (wire drift, still catchable)", async (_label, bad) => {
    const transport = new SdkMcpTransport({});
    const next = completionQueue(transport);
    transport.dispatch({ kind: "listTools", delegation: delegation(), descriptor: bad });
    typedThrowMessage(await next(), "prelude.mcp.server_error");
    transport.close();
  });

  test("an oauth descriptor with no credential store wired is the typed auth_error", async () => {
    const transport = new SdkMcpTransport({});
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: "http://127.0.0.1:1/mcp", auth: oauthAuth("github") },
    });
    const message = typedThrowMessage(await next(), "prelude.mcp.auth_error");
    expect(message).toContain("credential store");
    transport.close();
  });

  test("an oauth descriptor naming a missing credential is the typed auth_error naming the fix", async () => {
    const transport = new SdkMcpTransport({ credentials: memoryStore() });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: "http://127.0.0.1:1/mcp", auth: oauthAuth("github") },
    });
    const message = typedThrowMessage(await next(), "prelude.mcp.auth_error");
    expect(message).toContain('"github"');
    expect(message).toContain("katari mcp login");
    transport.close();
  });
});

// ─── the live paths: a real loopback MCP server observing the request headers ────────────────────

function readBody(request: IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
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
}

let httpServer: Server;
let url = "";
/** Every Authorization / x-katari-test header the server saw, in arrival order. */
const seenAuthorization: Array<string | undefined> = [];
const seenTestHeader: Array<string | undefined> = [];

beforeAll(async () => {
  // A stateless streamable-HTTP MCP server (fresh server + transport per request) that records the
  // auth-relevant request headers, so the tests can assert what each descriptor variant sent.
  httpServer = createServer((request, response) => {
    void (async () => {
      seenAuthorization.push(request.headers.authorization);
      const testHeader = request.headers["x-katari-test"];
      seenTestHeader.push(Array.isArray(testHeader) ? testHeader.join(",") : testHeader);
      const mcp = new McpServer({ name: "mcp-oauth-test", version: "1.0.0" });
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
  await new Promise<void>((resolve) => httpServer.listen(0, "127.0.0.1", resolve));
  url = `http://127.0.0.1:${(httpServer.address() as AddressInfo).port}/mcp`;
});

afterAll(async () => {
  httpServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    httpServer.close(() => resolve());
  });
});

describe("the two auth variants over a live server", () => {
  test("a headers descriptor rides its values as request headers", async () => {
    const transport = new SdkMcpTransport({});
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url, auth: headersAuth({ "x-katari-test": "ride-along" }) },
    });
    const completion = await next();
    expect(completion.outcome.kind).toBe("result");
    expect(seenTestHeader).toContain("ride-along");
    transport.close();
  }, 20000);

  test("an oauth descriptor injects the STORED bearer token via the SDK's authProvider", async () => {
    const store = memoryStore({
      github: { ...CREDENTIAL, resourceUrl: url },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url, auth: oauthAuth("github") },
    });
    const completion = await next();
    expect(completion.outcome.kind).toBe("result");
    // The token came from the store, not the program: no token material was in the descriptor.
    expect(seenAuthorization).toContain("Bearer token-123");
    transport.close();
  }, 20000);
});
