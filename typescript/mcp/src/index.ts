// The MCP OAuth authorization flow, as a library so its seams are testable without a browser.
// `performLogin` runs the OAuth 2.1 authorization-code + PKCE flow (with dynamic client registration)
// against one MCP server through the official SDK's `auth(...)` orchestrator, driving it with an
// in-memory provider:
//
//   1. a loopback redirect listener starts on an ephemeral port (its URL becomes the client's
//      registered redirect_uri);
//   2. the first `auth(...)` call discovers the server's authorization metadata, registers the client,
//      and hands back the authorization URL (the provider's `redirectToAuthorization` captures it —
//      the CALLER shows it to the user and may try a local browser);
//   3. the user authorizes in their browser; the IdP redirects to the loopback listener with the code
//      (the `state` parameter is checked against the one this flow minted);
//   4. the second `auth(...)` call exchanges the code (PKCE verifier included) for tokens.
//
// The result is the CREDENTIAL — tokens + the registered client information + the server url — held in
// memory for the one connection that needs it. `list-tools --oauth` (spawned by `katari mcp pull
// --oauth`) is the sole caller: a pull is a dev-time read, so the credential authorizes that single
// listing and is never persisted. Runtime credential storage and the human-facing authorization
// prompt now live in the runtime itself (an OAuth escalation), so this helper stays a listing concern.

import { randomBytes } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import {
  auth,
  type OAuthClientProvider,
  UnauthorizedError,
} from "@modelcontextprotocol/sdk/client/auth.js";
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";

/** The credential the flow yields: the OAuth tokens, the dynamically registered client information,
 *  and the server url. `list-tools --oauth` holds one in memory for a single listing. */
export interface McpLoginCredential {
  tokens: OAuthTokens;
  clientInformation: OAuthClientInformationMixed;
  resourceUrl: string;
}

/** What `performLogin` needs: the server url, and optionally the OAuth scope(s) to request. */
export interface LoginArguments {
  url: string;
  scope?: string;
}

/** The outcome of one loopback redirect hit: the authorization code, or why it is unusable. */
export type AuthorizationCallback =
  | { kind: "code"; code: string }
  | { kind: "rejected"; message: string };

/** Read the authorization response out of the redirect request's URL: the IdP sends `code` + `state`
 *  on success, `error` (+ `error_description`) on refusal. A `state` mismatch is rejected — the reply
 *  is not for the request this flow minted. */
export function parseAuthorizationCallback(
  requestUrl: string,
  expectedState: string,
): AuthorizationCallback {
  const parsed = new URL(requestUrl, "http://127.0.0.1");
  const oauthError = parsed.searchParams.get("error");
  if (oauthError !== null) {
    const description = parsed.searchParams.get("error_description");
    return {
      kind: "rejected",
      message: description === null ? oauthError : `${oauthError}: ${description}`,
    };
  }
  const code = parsed.searchParams.get("code");
  if (code === null || code === "") {
    return { kind: "rejected", message: "the authorization redirect carried no code" };
  }
  if (parsed.searchParams.get("state") !== expectedState) {
    return { kind: "rejected", message: "the authorization redirect carried a mismatched state" };
  }
  return { kind: "code", code };
}

/** The interactive login provider: everything in memory (the flow lives and dies in one process),
 *  dynamic registration enabled by implementing `saveClientInformation`. */
class LoginProvider implements OAuthClientProvider {
  authorizationUrl: URL | null = null;
  private registeredClient: OAuthClientInformationMixed | undefined;
  private currentTokens: OAuthTokens | undefined;
  private verifier: string | undefined;

  constructor(
    private readonly loopbackRedirectUrl: string,
    private readonly oauthState: string,
    private readonly scope: string | undefined,
  ) {}

  get redirectUrl(): string {
    return this.loopbackRedirectUrl;
  }

  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "katari",
      redirect_uris: [this.loopbackRedirectUrl],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      // A CLI cannot keep a secret, so it registers as a public client; token requests then
      // authenticate with PKCE alone (and the runtime refreshes the same way).
      token_endpoint_auth_method: "none",
      ...(this.scope === undefined ? {} : { scope: this.scope }),
    };
  }

  state(): string {
    return this.oauthState;
  }

  clientInformation(): OAuthClientInformationMixed | undefined {
    return this.registeredClient;
  }

  saveClientInformation(clientInformation: OAuthClientInformationMixed): void {
    this.registeredClient = clientInformation;
  }

  tokens(): OAuthTokens | undefined {
    return this.currentTokens;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.currentTokens = tokens;
  }

  redirectToAuthorization(authorizationUrl: URL): void {
    this.authorizationUrl = authorizationUrl;
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.verifier = codeVerifier;
  }

  codeVerifier(): string {
    if (this.verifier === undefined) {
      throw new Error("no PKCE verifier was saved before the code exchange");
    }
    return this.verifier;
  }

  /** The flow's result, once `auth(...)` reported AUTHORIZED. */
  credential(resourceUrl: string): McpLoginCredential {
    if (this.currentTokens === undefined || this.registeredClient === undefined) {
      throw new Error("the flow completed without tokens or client information");
    }
    return {
      tokens: this.currentTokens,
      clientInformation: this.registeredClient,
      resourceUrl,
    };
  }
}

export interface LoginCallbacks {
  /** Show the user the authorization URL (and any progress lines) — the CLI prints to stderr, so
   *  stdout stays pure JSON. */
  log: (line: string) => void;
  /** Best-effort local browser launch; failures are fine (the URL was already printed). */
  openBrowser?: (url: string) => void;
}

/** Run the whole login flow against `url`; resolves to the credential to store. Rejects when the
 *  server needs no OAuth (nothing to store), when the IdP refuses, or when the flow breaks. */
export async function performLogin(
  { url, scope }: LoginArguments,
  callbacks: LoginCallbacks,
): Promise<McpLoginCredential> {
  const oauthState = randomBytes(16).toString("hex");

  // The loopback listener first: its actual (ephemeral) port becomes the registered redirect_uri.
  let settleCallback: (callback: AuthorizationCallback) => void = () => {};
  const callbackArrived = new Promise<AuthorizationCallback>((resolve) => {
    settleCallback = resolve;
  });
  const listener = createServer((request, response) => {
    const outcome = parseAuthorizationCallback(request.url ?? "/", oauthState);
    response.writeHead(outcome.kind === "code" ? 200 : 400, {
      "content-type": "text/html; charset=utf-8",
    });
    response.end(
      outcome.kind === "code"
        ? "<p>Authorized. You can close this tab and return to the terminal.</p>"
        : `<p>Authorization failed: ${outcome.message}</p>`,
    );
    settleCallback(outcome);
  });
  await new Promise<void>((resolve) => listener.listen(0, "127.0.0.1", resolve));

  try {
    const port = (listener.address() as AddressInfo).port;
    const provider = new LoginProvider(`http://127.0.0.1:${port}/callback`, oauthState, scope);

    // Round one: discovery + dynamic registration + the authorization URL (via the provider).
    const firstRound = await auth(provider, {
      serverUrl: url,
      ...(scope === undefined ? {} : { scope }),
    });
    if (firstRound === "AUTHORIZED") {
      // No interaction was needed (e.g. the server accepted a non-interactive grant).
      return provider.credential(url);
    }
    if (provider.authorizationUrl === null) {
      throw new Error("the authorization flow produced no authorization URL");
    }
    const authorizationUrl = provider.authorizationUrl.toString();
    callbacks.log("Open this URL in your browser to authorize:");
    callbacks.log("");
    callbacks.log(`  ${authorizationUrl}`);
    callbacks.log("");
    callbacks.log("Waiting for the authorization to complete...");
    callbacks.openBrowser?.(authorizationUrl);

    const outcome = await callbackArrived;
    if (outcome.kind === "rejected") {
      throw new Error(`authorization failed: ${outcome.message}`);
    }

    // Round two: exchange the code (the provider supplies the PKCE verifier, saves the tokens).
    const secondRound = await auth(provider, {
      serverUrl: url,
      authorizationCode: outcome.code,
      ...(scope === undefined ? {} : { scope }),
    });
    if (secondRound !== "AUTHORIZED") {
      throw new Error("the token exchange did not authorize");
    }
    return provider.credential(url);
  } catch (error) {
    // The SDK's UnauthorizedError carries little context; rewrap it with the actionable part.
    if (error instanceof UnauthorizedError) {
      throw new Error(`the server refused the authorization flow: ${error.message}`);
    }
    throw error;
  } finally {
    listener.closeAllConnections();
    await new Promise<void>((resolve) => {
      listener.close(() => resolve());
    });
  }
}
