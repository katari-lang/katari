// The mcp auth sum, end to end at the transport seam: descriptor decoding (both variants, and the
// malformed shapes that must fail as TYPED throws, never engine errors), the stored-credential
// provider (token read, refresh write-back through the store with integer-generation compare-and-set,
// the interactive step refusing as the `McpAuthorizationRequired` park signal), and the live paths over
// real loopback servers — a `headers` descriptor riding its values as request headers, an `oauth`
// descriptor injecting the stored bearer token via the SDK's `authProvider`, and a 401-everything server
// exercising the classification split: `headers` + 401 → typed `auth_error`, `oauth` + 401 →
// `authorizationRequired` (the park signal the reactor escalates — never a typed error). What is NOT
// tested here: the park/retry loop itself (the reactor's — see mcp-authorize-escalation.test.ts) and a
// real IdP round-trip (the interactive flow is runtime-hosted and exercised elsewhere).

import { createServer, type IncomingMessage, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import type { Json } from "@katari-lang/types";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import {
  decodeMcpOAuthCredential,
  McpAuthorizationRequired,
  type McpCredentialStore,
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

/** An in-memory credential store: what the facade's repository-backed store does, minus the database.
 *  Each stored credential carries a monotonically increasing integer generation; `save` is a
 *  compare-and-set against it (resolving to whether the write took), and `replace` simulates the
 *  authorization flow's unconditional upsert overwriting the credential out of band. */
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
        : { credential: entry.credential, generation: entry.generation };
    },
    async save(name, credential, expectedGeneration) {
      const entry = entries.get(name);
      // A stale generation (the credential was replaced since it was read — a fresh authorization)
      // refuses the write.
      if (entry !== undefined && entry.generation !== expectedGeneration) return false;
      sequence += 1;
      entries.set(name, { credential, generation: sequence });
      saved.push({ name, credential });
      return true;
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

/** Assert a completion is the oauth park signal and return its `{ url, name }` for content checks. */
function authorizationRequiredOf(completion: McpCompletion): { url: string; name: string } {
  if (completion.outcome.kind !== "authorizationRequired") {
    throw new Error(`expected an authorizationRequired completion, got ${completion.outcome.kind}`);
  }
  return { url: completion.outcome.url, name: completion.outcome.name };
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

describe("decodeMcpOAuthCredential", () => {
  test("round-trips the blob the authorization flow deposits", () => {
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
  ])("an unreadable blob (%s) is the park signal naming the credential", (_label, raw) => {
    // An unreadable credential cannot authenticate anything — same remedy as a missing one (a fresh
    // interactive authorization), so the same park signal: never a typed error on the oauth path.
    expect(() => decodeMcpOAuthCredential("github", raw)).toThrowError(McpAuthorizationRequired);
    expect(() => decodeMcpOAuthCredential("github", raw)).toThrowError(/authorization/);
    try {
      decodeMcpOAuthCredential("github", raw);
    } catch (error) {
      if (!(error instanceof McpAuthorizationRequired)) throw error;
      expect(error.credentialName).toBe("github");
    }
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

  test("reads through on each use, so a warm provider serves a re-authorization's replaced credential", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    const provider = new StoredMcpOAuthProvider("github", store);
    expect((await provider.tokens()).access_token).toBe("token-123");
    // A fresh authorization replaces the stored credential out of band (the flow's upsert).
    store.replace("github", {
      ...CREDENTIAL,
      tokens: { access_token: "reauth-999", token_type: "Bearer", refresh_token: "reauth-r" },
    });
    // The warm provider does NOT keep serving the stale token — it reads through on the next use.
    expect((await provider.tokens()).access_token).toBe("reauth-999");
  });

  test("a refresh write-back refuses to clobber a credential a re-authorization replaced under it", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    const provider = new StoredMcpOAuthProvider("github", store);
    // The provider reads the credential (the read that drives an about-to-happen refresh)…
    expect((await provider.tokens()).access_token).toBe("token-123");
    // …then a fresh authorization replaces it before that refresh's write-back lands.
    store.replace("github", {
      ...CREDENTIAL,
      tokens: { access_token: "reauth-999", token_type: "Bearer", refresh_token: "reauth-r" },
    });
    // The stale write-back is refused (compare-and-set on the integer generation it read), so nothing
    // is saved…
    await provider.saveTokens({ access_token: "stale-refresh", token_type: "Bearer" });
    expect(store.saved).toHaveLength(0);
    // …and the newer credential stands.
    expect((await provider.tokens()).access_token).toBe("reauth-999");
  });

  test("a missing credential is the park signal (the runtime cannot authorize on its own)", async () => {
    const provider = new StoredMcpOAuthProvider("github", memoryStore());
    await expect(provider.tokens()).rejects.toThrowError(McpAuthorizationRequired);
    await expect(provider.clientInformation()).rejects.toThrowError(McpAuthorizationRequired);
  });

  test("the interactive steps refuse as the park signal", () => {
    const provider = new StoredMcpOAuthProvider("github", memoryStore());
    expect(() => provider.redirectToAuthorization()).toThrowError(McpAuthorizationRequired);
    expect(() => provider.codeVerifier()).toThrowError(McpAuthorizationRequired);
    expect(() => provider.saveCodeVerifier()).toThrowError(McpAuthorizationRequired);
  });

  test("presents a redirect url so the SDK attempts the refresh grant before the interactive step", () => {
    // Load-bearing subtlety: the SDK reads an undefined `redirectUrl` as a non-interactive grant and
    // then never tries the refresh path at all. The placeholder is never actually redirected to (the
    // PKCE steps above throw first).
    const provider = new StoredMcpOAuthProvider("github", memoryStore());
    expect(provider.redirectUrl).toBe("urn:ietf:wg:oauth:2.0:oob");
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
    const transport = new SdkMcpTransport({ credentials: memoryStore() });
    const next = completionQueue(transport);
    transport.dispatch({ kind: "listTools", delegation: delegation(), descriptor: bad });
    typedThrowMessage(await next(), "prelude.mcp.server_error");
    transport.close();
  });

  test("an oauth descriptor naming a missing credential parks before any network I/O", async () => {
    // The url points nowhere reachable on purpose: the pre-flight store read must decide this BEFORE
    // any SDK machinery touches the network, and the completion carries the descriptor's identity.
    const transport = new SdkMcpTransport({ credentials: memoryStore() });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: "http://127.0.0.1:1/mcp", auth: oauthAuth("github") },
    });
    expect(authorizationRequiredOf(await next())).toEqual({
      url: "http://127.0.0.1:1/mcp",
      name: "github",
    });
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
/** A server that answers 401 to EVERYTHING (tool traffic, discovery, token endpoint) — the shape of a
 *  server whose grant was revoked, and of a headers deployment whose key material is wrong. */
let unauthorizedServer: Server;
let unauthorizedUrl = "";
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

  unauthorizedServer = createServer((_request, response) => {
    response.writeHead(401, { "content-type": "text/plain" }).end("unauthorized");
  });
  await new Promise<void>((resolve) => unauthorizedServer.listen(0, "127.0.0.1", resolve));
  unauthorizedUrl = `http://127.0.0.1:${(unauthorizedServer.address() as AddressInfo).port}/mcp`;
});

afterAll(async () => {
  httpServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    httpServer.close(() => resolve());
  });
  unauthorizedServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    unauthorizedServer.close(() => resolve());
  });
});

describe("the two auth variants over a live server", () => {
  test("a headers descriptor rides its values as request headers", async () => {
    const transport = new SdkMcpTransport({ credentials: memoryStore() });
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

describe("a 401-everything server splits by the auth variant", () => {
  test("headers + 401 is the typed auth_error (the same material will not start working)", async () => {
    const transport = new SdkMcpTransport({ credentials: memoryStore() });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: unauthorizedUrl, auth: headersAuth({ authorization: "Bearer wrong" }) },
    });
    const message = typedThrowMessage(await next(), "prelude.mcp.auth_error");
    expect(message).toContain("key material");
    transport.close();
  }, 20000);

  test("oauth + 401 parks (a stored credential the server rejects beyond refresh)", async () => {
    // The credential exists and looks healthy, but the server 401s everything — including the refresh
    // attempt the SDK makes. The flow then reaches the interactive step, which the provider refuses as
    // the park signal; the classification NEVER lets an oauth failure become a typed error.
    const store = memoryStore({
      github: { ...CREDENTIAL, resourceUrl: unauthorizedUrl },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: unauthorizedUrl, auth: oauthAuth("github") },
    });
    expect(authorizationRequiredOf(await next())).toEqual({
      url: unauthorizedUrl,
      name: "github",
    });
    transport.close();
  }, 20000);
});
