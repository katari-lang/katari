// The mcp auth sum end to end at the transport seam, over the credentials core: descriptor decoding (both
// variants, and the malformed shapes that must fail as TYPED throws, never engine errors), the stored
// credential's decode (the current profile-tagged shape AND the migrated prototype triple), on-demand
// token resolution + refresh (`resolveToken` — a clock-valid token served as-is, an expired one refreshed
// against the STORED token endpoint with an integer-generation compare-and-set write-back, a refresh-dead
// one parking), and the live paths over real loopback servers — a `headers` descriptor riding its values
// as request headers, an `oauth` descriptor injecting the resolved bearer token, and a 401-everything
// server exercising the classification split: `headers` + 401 → typed `auth_error`, `oauth` + 401 →
// `authorizationRequired` (the park signal the reactor escalates — never a typed error). What is NOT
// tested here: the park/retry loop itself (the reactor's — see mcp-authorize-escalation.test.ts) and a
// real IdP round-trip (the interactive flow is runtime-hosted and exercised in mcp-authorization-flow).

import {
  createServer,
  type IncomingMessage,
  type Server,
  type ServerResponse,
} from "node:http";
import type { AddressInfo } from "node:net";
import type { Json } from "@katari-lang/types";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { z } from "zod";
import {
  CredentialAuthorizationRequired,
  type CredentialStore,
  decodeStoredCredential,
  resolveToken,
  type StoredCredential,
} from "../src/runtime/external/credentials.js";
import {
  type McpCompletion,
  type McpTransport,
  SdkMcpTransport,
} from "../src/runtime/external/mcp-transport.js";
import type { DelegationId } from "../src/runtime/ids.js";

/** The current profile-tagged stored shape, with no known expiry (used until the server rejects it). */
const CREDENTIAL: StoredCredential = {
  profile: "mcp",
  accessToken: "token-123",
  refreshToken: "refresh-123",
  expiresAt: null,
  tokenEndpoint: "https://idp.example.test/token",
  scopes: ["read"],
  clientInformation: { client_id: "client-123" },
  resourceUrl: "https://mcp.example.test/mcp",
};

/** The prototype's credential triple a migrated `credentials` row still holds — decode must map it. */
const MIGRATED_TRIPLE = {
  tokens: { access_token: "token-legacy", token_type: "Bearer", refresh_token: "refresh-legacy" },
  clientInformation: { client_id: "client-legacy" },
  resourceUrl: "https://mcp.example.test/mcp",
};

/** An in-memory credential store: what the facade's repository-backed store does, minus the database.
 *  Each stored credential carries a monotonically increasing integer generation; `save` is a
 *  compare-and-set against it (resolving to whether the write took). */
function memoryStore(seed: Record<string, StoredCredential> = {}): CredentialStore & {
  saved: Array<{ name: string; credential: StoredCredential }>;
} {
  const entries = new Map<string, { credential: StoredCredential; generation: number }>();
  let sequence = 0;
  for (const [name, credential] of Object.entries(seed)) {
    sequence += 1;
    entries.set(name, { credential, generation: sequence });
  }
  const saved: Array<{ name: string; credential: StoredCredential }> = [];
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

describe("decodeStoredCredential", () => {
  test("round-trips the current profile-tagged shape", () => {
    const decoded = decodeStoredCredential("github", JSON.stringify(CREDENTIAL));
    expect(decoded).toEqual(CREDENTIAL);
  });

  test("decodes the migrated prototype triple, stamping the mcp profile and an empty token endpoint", () => {
    const decoded = decodeStoredCredential("github", JSON.stringify(MIGRATED_TRIPLE));
    expect(decoded.profile).toBe("mcp");
    expect(decoded.accessToken).toBe("token-legacy");
    expect(decoded.refreshToken).toBe("refresh-legacy");
    // No token endpoint was persisted by the prototype — the first refresh re-discovers it.
    expect(decoded.tokenEndpoint).toBe("");
    // Unknown issue time → unknown expiry, so the token is used until a 401.
    expect(decoded.expiresAt).toBeNull();
    expect(decoded.resourceUrl).toBe("https://mcp.example.test/mcp");
  });

  test("keeps the client secret a confidential client refreshes with", () => {
    const decoded = decodeStoredCredential(
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
    ["missing accessToken and tokens", JSON.stringify({ resourceUrl: "x" })],
    ["a current shape missing the token endpoint", JSON.stringify({ ...CREDENTIAL, tokenEndpoint: undefined })],
    ["a migrated triple missing the resource url", JSON.stringify({ ...MIGRATED_TRIPLE, resourceUrl: undefined })],
  ])("an unreadable blob (%s) is the park signal naming the credential", (_label, raw) => {
    // An unreadable credential cannot authenticate anything — same remedy as a missing one (a fresh
    // interactive authorization), so the same park signal: never a typed error on the oauth path.
    expect(() => decodeStoredCredential("github", raw)).toThrowError(CredentialAuthorizationRequired);
    try {
      decodeStoredCredential("github", raw);
    } catch (error) {
      if (!(error instanceof CredentialAuthorizationRequired)) throw error;
      expect(error.credentialName).toBe("github");
    }
  });
});

// ─── resolveToken: the on-demand token resolution + refresh, over a fake token endpoint ──────────────

let tokenServer: Server;
let tokenEndpoint = "";
/** The fake identity provider's origin — a migrated credential's `resourceUrl` points here, so RFC 9728
 *  discovery (its protected-resource probe 404s, its authorization-server metadata answers) resolves the
 *  token endpoint the way the shipped SDK provider used to. */
let discoveryBase = "";
/** Every refresh grant the fake token endpoint received, in arrival order (for asserting what was sent). */
const refreshRequests: Array<URLSearchParams> = [];
/** How the fake token endpoint answers a grant: rotate to a fresh token, refuse with a 400
 *  `invalid_grant` (a dead refresh token — the permanent failure), or fail with a 503 (an outage — the
 *  transient one). */
let tokenServerMode: "rotate" | "refuse" | "unavailable" = "rotate";
let rotationCounter = 0;

/** Answer one discovery probe, or hand back `false` for non-discovery traffic. The protected-resource
 *  probe 404s (no RFC 9728 document — the SDK then treats the server itself as the authorization
 *  server), and the authorization-server / OIDC metadata advertises the fake token endpoint. */
function answerDiscovery(
  request: IncomingMessage,
  response: ServerResponse,
  base: string,
): boolean {
  const path = request.url ?? "";
  if (!path.includes("/.well-known/")) return false;
  if (path.includes("/.well-known/oauth-protected-resource")) {
    response.writeHead(404).end();
    return true;
  }
  response.writeHead(200, { "content-type": "application/json" });
  response.end(
    JSON.stringify({
      issuer: base,
      authorization_endpoint: `${base}/authorize`,
      token_endpoint: tokenEndpoint,
      response_types_supported: ["code"],
    }),
  );
  return true;
}

beforeAll(async () => {
  tokenServer = createServer((request, response) => {
    void (async () => {
      if (answerDiscovery(request, response, discoveryBase)) return;
      let raw = "";
      request.setEncoding("utf8");
      for await (const chunk of request) raw += chunk;
      refreshRequests.push(new URLSearchParams(raw));
      if (tokenServerMode === "refuse") {
        response.writeHead(400, { "content-type": "application/json" });
        response.end(JSON.stringify({ error: "invalid_grant" }));
        return;
      }
      if (tokenServerMode === "unavailable") {
        response.writeHead(503, { "content-type": "text/plain" });
        response.end("maintenance");
        return;
      }
      rotationCounter += 1;
      response.writeHead(200, { "content-type": "application/json" });
      response.end(
        JSON.stringify({
          access_token: `rotated-${rotationCounter}`,
          token_type: "Bearer",
          expires_in: 3600,
        }),
      );
    })().catch(() => {
      if (!response.headersSent) response.writeHead(500).end();
    });
  });
  await new Promise<void>((resolve) => tokenServer.listen(0, "127.0.0.1", resolve));
  discoveryBase = `http://127.0.0.1:${(tokenServer.address() as AddressInfo).port}`;
  tokenEndpoint = `${discoveryBase}/token`;
});

afterAll(async () => {
  tokenServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    tokenServer.close(() => resolve());
  });
});

describe("resolveToken", () => {
  test("serves a clock-valid token without touching the network", async () => {
    const store = memoryStore({
      github: { ...CREDENTIAL, expiresAt: Date.now() + 3_600_000 },
    });
    expect(await resolveToken(store, "github")).toEqual({ kind: "token", token: "token-123" });
    expect(store.saved).toHaveLength(0);
  });

  test("serves a token with no known expiry as-is (a later 401 supplies the rejected-token hint)", async () => {
    const store = memoryStore({ github: CREDENTIAL });
    expect(await resolveToken(store, "github")).toEqual({ kind: "token", token: "token-123" });
    expect(store.saved).toHaveLength(0);
  });

  test("a rejected-token hint outranks the stored clock: a clock-valid token the server 401'd refreshes", async () => {
    tokenServerMode = "rotate";
    refreshRequests.length = 0;
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-123",
        expiresAt: Date.now() + 3_600_000,
        tokenEndpoint,
      },
    });
    const resolution = await resolveToken(store, "github", "token-123");
    expect(resolution.kind).toBe("token");
    if (resolution.kind !== "token") throw new Error("unreachable");
    expect(resolution.token).toMatch(/^rotated-/);
    expect(refreshRequests).toHaveLength(1);
    expect(store.saved.at(-1)?.credential.accessToken).toBe(resolution.token);
  });

  test("a rejected-token hint that no longer matches the stored token serves the replacement as-is", async () => {
    // A fresh authorization (or another resolution's refresh) already replaced the rejected token; the
    // hint is stale, so the replacement is served by the normal rules — no grant fires.
    refreshRequests.length = 0;
    const store = memoryStore({
      github: { ...CREDENTIAL, accessToken: "reauth-999", tokenEndpoint },
    });
    expect(await resolveToken(store, "github", "token-123")).toEqual({
      kind: "token",
      token: "reauth-999",
    });
    expect(refreshRequests).toHaveLength(0);
  });

  test("a migrated credential's first rejected 401 discovers the token endpoint and backfills it", async () => {
    // The prototype triple stored no token endpoint and no expiry: its first 401 arrives with the
    // rejected-token hint, which forces the refresh branch — the endpoint is discovered (RFC 9728 against
    // the resource url) and the write-back persists it, so later refreshes skip discovery.
    tokenServerMode = "rotate";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-legacy",
        expiresAt: null,
        tokenEndpoint: "",
        resourceUrl: discoveryBase,
      },
    });
    const resolution = await resolveToken(store, "github", "token-123");
    expect(resolution.kind).toBe("token");
    const written = store.saved.at(-1)?.credential;
    expect(written?.tokenEndpoint).toBe(tokenEndpoint);
  });

  test("two concurrent resolutions of one expiring credential share ONE refresh grant", async () => {
    // A rotated refresh token is often single-use: racing refreshes would burn it twice and dead-end the
    // loser. The core single-flights the grant per (store, name).
    tokenServerMode = "rotate";
    refreshRequests.length = 0;
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-123",
        expiresAt: Date.now() - 1000,
        tokenEndpoint,
      },
    });
    const [first, second] = await Promise.all([
      resolveToken(store, "github"),
      resolveToken(store, "github"),
    ]);
    expect(refreshRequests).toHaveLength(1);
    expect(first).toEqual(second);
    expect(first.kind).toBe("token");
  });

  test("a missing credential is the park trigger", async () => {
    expect(await resolveToken(memoryStore(), "github")).toEqual({
      kind: "needsAuthorize",
      name: "github",
    });
  });

  test("an expired credential with no refresh token parks", async () => {
    const store = memoryStore({
      github: { ...CREDENTIAL, refreshToken: null, expiresAt: Date.now() - 1000 },
    });
    expect(await resolveToken(store, "github")).toEqual({
      kind: "needsAuthorize",
      name: "github",
    });
  });

  test("an expired credential refreshes against the stored token endpoint and writes the rotation back", async () => {
    tokenServerMode = "rotate";
    refreshRequests.length = 0;
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-123",
        expiresAt: Date.now() - 1000,
        tokenEndpoint,
      },
    });
    const resolution = await resolveToken(store, "github");
    expect(resolution.kind).toBe("token");
    if (resolution.kind !== "token") throw new Error("unreachable");
    expect(resolution.token).toBe(store.saved.at(-1)?.credential.accessToken);
    // The grant hit the STORED endpoint as a plain refresh_token grant carrying the client id.
    const grant = refreshRequests.at(-1);
    expect(grant?.get("grant_type")).toBe("refresh_token");
    expect(grant?.get("refresh_token")).toBe("refresh-123");
    expect(grant?.get("client_id")).toBe("client-123");
    // The rotation is durable, carries the (unchanged) refresh token forward, and re-stamps the expiry.
    const written = store.saved.at(-1)?.credential;
    expect(written?.refreshToken).toBe("refresh-123");
    expect(written?.expiresAt).toBeGreaterThan(Date.now());
    expect(written?.tokenEndpoint).toBe(tokenEndpoint);
  });

  test("a refresh the token endpoint refuses parks (refresh-dead → re-login)", async () => {
    tokenServerMode = "refuse";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-123",
        expiresAt: Date.now() - 1000,
        tokenEndpoint,
      },
    });
    expect(await resolveToken(store, "github")).toEqual({
      kind: "needsAuthorize",
      name: "github",
    });
    expect(store.saved).toHaveLength(0);
  });

  test("a token-endpoint outage (5xx) throws instead of parking — transient, never a human's problem", async () => {
    tokenServerMode = "unavailable";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        refreshToken: "refresh-123",
        expiresAt: Date.now() - 1000,
        tokenEndpoint,
      },
    });
    await expect(resolveToken(store, "github")).rejects.toThrowError(/token endpoint failed/);
    expect(store.saved).toHaveLength(0);
  });

  test("a refused write-back (a re-authorization won the compare-and-set) still returns the minted token", async () => {
    tokenServerMode = "rotate";
    // A store whose compare-and-set always loses — modelling a fresh authorization that replaced the
    // credential between this refresh's read and its write-back. The rotation this resolution just minted
    // is still valid to use, so the token is returned rather than treated as a failure.
    const refusingStore: CredentialStore = {
      load: async () => ({
        credential: {
          ...CREDENTIAL,
          refreshToken: "refresh-123",
          expiresAt: Date.now() - 1000,
          tokenEndpoint,
        },
        generation: 1,
      }),
      save: async () => false,
    };
    const resolution = await resolveToken(refusingStore, "github");
    expect(resolution.kind).toBe("token");
    if (resolution.kind !== "token") throw new Error("unreachable");
    expect(resolution.token).toMatch(/^rotated-/);
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
/** A server that answers 401 to EVERYTHING — the shape of a server whose grant was revoked, and of a
 *  headers deployment whose key material is wrong. */
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
    // The url points nowhere reachable on purpose: the pre-flight `resolveToken` must decide this BEFORE
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

  test("an oauth descriptor injects the resolved bearer token", async () => {
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
    // The token came from the store (resolved to a clock-valid token), not the program.
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

  test("oauth + 401 with no refresh token parks (nothing silent can fix the rejection)", async () => {
    // The credential resolves to a clock-valid token, but the server 401s everything and there is no
    // refresh token to try — the reactive park path: the classification never lets an oauth failure
    // become a typed error.
    const store = memoryStore({
      github: { ...CREDENTIAL, refreshToken: null, resourceUrl: unauthorizedUrl },
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

// ─── refresh-before-park: a guarded server that 401s stale tokens but accepts rotated ones ────────

/** A live MCP server that answers the discovery well-knowns and 401s any MCP request whose bearer token
 *  is not a `rotated-*` one the fake token endpoint minted — the shape of a server whose old token
 *  expired (or was revoked) while a fresh one authenticates fine. What the shipped SDK provider handled
 *  with its own refresh-on-401, and what `retryWithRefreshedToken` must now handle identically. */
let guardedServer: Server;
let guardedUrl = "";
let guardedBase = "";
/** Every bearer token the guarded server saw on MCP traffic, in arrival order. */
const guardedTokensSeen: Array<string | undefined> = [];

beforeAll(async () => {
  guardedServer = createServer((request, response) => {
    void (async () => {
      if (answerDiscovery(request, response, guardedBase)) return;
      const authorization = request.headers.authorization;
      guardedTokensSeen.push(authorization);
      if (authorization === undefined || !authorization.startsWith("Bearer rotated-")) {
        response.writeHead(401, { "content-type": "text/plain" }).end("unauthorized");
        return;
      }
      const mcp = new McpServer({ name: "mcp-guarded-test", version: "1.0.0" });
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
  await new Promise<void>((resolve) => guardedServer.listen(0, "127.0.0.1", resolve));
  guardedBase = `http://127.0.0.1:${(guardedServer.address() as AddressInfo).port}`;
  guardedUrl = `${guardedBase}/mcp`;
});

afterAll(async () => {
  guardedServer.closeAllConnections();
  await new Promise<void>((resolve) => {
    guardedServer.close(() => resolve());
  });
});

describe("a 401 gets a silent refresh-and-retry before anything parks", () => {
  test("a 401 on a clock-valid token refreshes and retries transparently — no park, no human", async () => {
    // The long-lived-scope shape: the stored clock still says valid, but the server rejects the token
    // (expiry drift, revocation). The 401 hands the rejected token to the core, the refresh rotates it,
    // and the SAME operation retries once with the fresh token — the run never notices.
    tokenServerMode = "rotate";
    const before = refreshRequests.length;
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        accessToken: "stale-token",
        refreshToken: "refresh-123",
        expiresAt: Date.now() + 3_600_000,
        tokenEndpoint,
        resourceUrl: guardedUrl,
      },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: guardedUrl, auth: oauthAuth("github") },
    });
    const completion = await next();
    expect(completion.outcome.kind).toBe("result");
    expect(refreshRequests.length).toBe(before + 1);
    // The server saw the stale token rejected, then the rotated one accepted.
    expect(guardedTokensSeen).toContain("Bearer stale-token");
    expect(guardedTokensSeen.at(-1)).toMatch(/^Bearer rotated-/);
    transport.close();
  }, 20000);

  test("a migrated credential 401s once, re-discovers its token endpoint, refreshes, and succeeds", async () => {
    // The prototype triple: no stored expiry (served as-is), no stored token endpoint. Its first 401
    // triggers the rejected-token refresh, whose endpoint discovery runs against the resource url; the
    // write-back backfills the endpoint so the next refresh skips discovery. No park, no human.
    tokenServerMode = "rotate";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        accessToken: "stale-token",
        refreshToken: "refresh-legacy",
        expiresAt: null,
        tokenEndpoint: "",
        resourceUrl: guardedUrl,
      },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: guardedUrl, auth: oauthAuth("github") },
    });
    const completion = await next();
    expect(completion.outcome.kind).toBe("result");
    expect(store.saved.at(-1)?.credential.tokenEndpoint).toBe(tokenEndpoint);
    transport.close();
  }, 20000);

  test("park only when refresh is dead: a 401 whose refresh is refused becomes authorizationRequired", async () => {
    tokenServerMode = "refuse";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        accessToken: "stale-token",
        refreshToken: "refresh-dead",
        expiresAt: Date.now() + 3_600_000,
        tokenEndpoint,
        resourceUrl: guardedUrl,
      },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: guardedUrl, auth: oauthAuth("github") },
    });
    expect(authorizationRequiredOf(await next())).toEqual({ url: guardedUrl, name: "github" });
    transport.close();
  }, 20000);

  test("a token-endpoint outage during the 401 refresh is the retryable server_error, never a park", async () => {
    tokenServerMode = "unavailable";
    const store = memoryStore({
      github: {
        ...CREDENTIAL,
        accessToken: "stale-token",
        refreshToken: "refresh-123",
        expiresAt: Date.now() + 3_600_000,
        tokenEndpoint,
        resourceUrl: guardedUrl,
      },
    });
    const transport = new SdkMcpTransport({ credentials: store });
    const next = completionQueue(transport);
    transport.dispatch({
      kind: "listTools",
      delegation: delegation(),
      descriptor: { url: guardedUrl, auth: oauthAuth("github") },
    });
    // A katari-level retry (or the next call) re-attempts once the outage clears — waking a human for
    // an identity provider's downtime would be the wrong contract.
    typedThrowMessage(await next(), "prelude.mcp.server_error");
    transport.close();
  }, 20000);
});
