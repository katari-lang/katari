// The runtime-hosted OAuth authorization flow (docs/2026-07-14-credentials-core.md §5 + Phase 2 §4–§6):
// the interactive counterpart of a `prelude.oauth.authorize` escalation, and the target of a proactive
// login. The runtime is a continuously running server, so it hosts the whole OAuth 2.1 authorization-code +
// PKCE flow itself (the browser only opens the URL this service mints, and returns to the runtime's public
// `/oauth/callback`). Two rounds, as before:
//
//   round 1 (`startForCredential` / `startFromEscalation`) — mint an authorization URL and park the flow
//                                state in memory under the minted OAuth `state` parameter;
//   round 2 (`handleCallback`)   — the identity provider redirects the browser back; the code is exchanged
//                                for tokens, the resolved `StoredCredential` (with the token endpoint the
//                                core later refreshes against) is deposited, and EVERY open authorize
//                                escalation waiting on that credential name is answered (value null — token
//                                material never rides an answer). Zero waiting escalations is fine: a
//                                proactive login is a pure deposit.
//
// THE ACQUISITION PROFILE IS A SUM DECIDED ONCE, at flow start, by whether a server `url` was supplied:
//   - a `url` present → the `mcp` profile: discovery + dynamic client registration + PKCE through the SDK's
//     `auth(...)` orchestrator (an MCP server advertises its own authorization server; the client is
//     registered on the fly). This is the Phase 1 path, unchanged.
//   - no `url` → the `configured` profile: a plain OAuth 2.1 authorization-code + PKCE flow against an
//     operator-registered client (the `oauth_clients` registry — endpoints, client id, an optional client
//     secret, scopes). No discovery, no registration; the endpoints are explicit. A missing registration is
//     a 400.
// Everything past the acquisition step — the flow-state map, the public callback, the deposit + answer-all —
// is profile-INDEPENDENT: the two arms differ only in how round 1 mints the URL and round 2 exchanges the
// code into a `StoredCredential`.
//
// Flow state is deliberately IN-MEMORY with a short TTL, keyed by (project, name): the durable thing is the
// credential (and any escalation waiting on it), and a flow lost to a restart (or expiry) is restarted by
// asking again. Re-keying by (project, name) — NOT by escalation — means a restart of the login for a name
// REPLACES its pending flow; the completion answers whatever escalations happen to be waiting on that name.

import { createHash, randomBytes, randomUUID } from "node:crypto";
import {
  auth,
  type OAuthClientProvider,
  type OAuthDiscoveryState,
} from "@modelcontextprotocol/sdk/client/auth.js";
import {
  type OAuthClientInformationMixed,
  type OAuthClientMetadata,
  type OAuthTokens,
  OAuthTokensSchema,
} from "@modelcontextprotocol/sdk/shared/auth.js";
import { BadRequestError, ConflictError, NotFoundError } from "../../lib/errors.js";
import { messageOf } from "../actor/failure.js";
import type { Value } from "../value/types.js";
import { OAUTH_AUTHORIZE_REQUEST, type StoredCredential } from "./credentials.js";

/** How long a started flow stays redeemable. Long enough for a human to authenticate at the identity
 *  provider; short enough that an abandoned `state` capability does not accumulate. */
export const AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS = 10 * 60 * 1000;

/** The `{ name, url? }` payload of a `prelude.oauth.authorize` escalation, read out of its argument `Value`.
 *  The `name` is always present; the `url` is present only for the mcp profile (a server the human sees) —
 *  a configured credential's escalation carries just the name (`url` is `null`, a genuine absence, not an
 *  odd input). Null when the argument carries no readable name (the argument is runtime-synthesized, so
 *  null means the row is damaged, not that a user sent something odd). */
export function oauthAuthorizeArgumentOf(
  argument: Value | null,
): { url: string | null; name: string } | null {
  if (argument === null || argument.kind !== "record") return null;
  const name = argument.fields.name;
  if (name === undefined || name.kind !== "string") return null;
  const url = argument.fields.url;
  return { url: url !== undefined && url.kind === "string" ? url.value : null, name: name.value };
}

/** One open escalation as the flow consumes it — just enough to recognise an authorize row and read its
 *  payload. Both escalation lookups the flow depends on speak this shape. */
export interface OpenEscalationCandidate {
  id: string;
  request: string;
  argument: Value | null;
}

/** A `configured` client's registered configuration the flow needs to run its plain OAuth 2.1 code + PKCE
 *  flow — the endpoints, the client id, the (unsealed) optional client secret, the scopes, and any extra
 *  authorize-URL parameters. Declared here as the flow's own port; the module binding wires it to the
 *  `oauth_clients` registry. */
export interface RegisteredClient {
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  /** The client secret, or `null` for a public client (PKCE only — a genuine absence). */
  clientSecret: string | null;
  scopes: string[];
  /** Extra provider-specific query parameters appended verbatim to the authorization URL — registry DATA,
   *  not a code branch (e.g. Google issues a refresh token only with `access_type=offline` +
   *  `prompt=consent`). A standard parameter wins on a name collision (see `startConfigured`). */
  authorizationParameters: Record<string, string>;
}

/** What the flow needs from the host, injected so the service is testable against stubs and a fake
 *  identity provider without the database or the engine. */
export interface AuthorizationFlowDependencies {
  /** The public base URL this runtime is reachable at (`config.publicUrl`); the redirect_uri is minted
   *  as `<publicUrl>/oauth/callback` — the same one-address-one-knob as webhook / serve minted URLs. */
  publicUrl: string;
  /** One open escalation by id, or undefined when it does not exist (or was already answered) — the
   *  escalation-driven login derives `{ name, url? }` from it. */
  loadOpenEscalation(
    projectId: string,
    escalationId: string,
  ): Promise<OpenEscalationCandidate | undefined>;
  /** Every open escalation of a project — the callback answers all authorize rows naming the credential. */
  listOpenEscalations(projectId: string): Promise<OpenEscalationCandidate[]>;
  /** The registered `configured` client for a credential name, or null when none is registered (a 400). */
  loadClientConfig(projectId: string, name: string): Promise<RegisteredClient | null>;
  /** Deposit the completed `StoredCredential` (the unconditional, generation-bumping upsert). */
  depositCredential(projectId: string, name: string, credential: StoredCredential): Promise<void>;
  /** Answer one open escalation with value null (the resume signal; the raiser re-reads the store). */
  answerEscalation(projectId: string, escalationId: string): Promise<void>;
  /** Operator-facing logging for the one swallowed failure (a per-escalation answer that did not land
   *  after a successful deposit): the affected run stays parked behind an "Authorized" page, so the
   *  event must be visible somewhere other than the user's closed browser tab. */
  warn(message: string, context: Record<string, unknown>): void;
  /** The clock, injectable so tests can drive TTL expiry. */
  now(): number;
}

/** What round 2 must remember from round 1, keyed by the minted `state`: the (project, name) it authorizes,
 *  the PKCE verifier, and the profile-specific material to exchange the code. NO escalation id — the flow is
 *  keyed by (project, name), so its completion answers whatever escalations are waiting on that name. */
type PendingAuthorizationFlow = {
  projectId: string;
  name: string;
  codeVerifier: string;
  expiresAt: number;
} & (
  | { profile: "mcp"; url: string; clientInformation: OAuthClientInformationMixed }
  | {
      profile: "configured";
      tokenEndpoint: string;
      clientId: string;
      clientSecret: string | null;
      scopes: string[];
    }
);

/** What round 2 seeds the mcp provider with; round 1 starts from nothing (dynamic registration fills it). */
interface AuthorizationFlowSeed {
  clientInformation: OAuthClientInformationMixed;
  codeVerifier: string;
}

/** The in-memory provider driving the SDK's `auth(...)` orchestrator for one mcp-profile round. Interactive
 *  pieces are captured, not performed: `redirectToAuthorization` records the URL for the API response, and
 *  the registered client / PKCE verifier are read back into the pending-flow entry. */
class AuthorizationFlowProvider implements OAuthClientProvider {
  capturedAuthorizationUrl: URL | null = null;
  /** The token endpoint the SDK discovered (RFC 8414 / OIDC) — captured so the deposited credential
   *  persists it and the core's later refreshes need no re-discovery (the crux of the rebuild). */
  private discoveredTokenEndpoint: string | undefined;
  private registeredClient: OAuthClientInformationMixed | undefined;
  private exchangedTokens: OAuthTokens | undefined;
  private pkceCodeVerifier: string | undefined;

  constructor(
    private readonly callbackUrl: string,
    private readonly mintedState: string,
    seed: AuthorizationFlowSeed | null,
  ) {
    if (seed !== null) {
      this.registeredClient = seed.clientInformation;
      this.pkceCodeVerifier = seed.codeVerifier;
    }
  }

  get redirectUrl(): string {
    return this.callbackUrl;
  }

  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "katari-runtime",
      redirect_uris: [this.callbackUrl],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      // The runtime registers as a public client: token requests authenticate with PKCE alone, and the
      // stored credential refreshes the same way — no client secret to keep.
      token_endpoint_auth_method: "none",
    };
  }

  state(): string {
    return this.mintedState;
  }

  clientInformation(): OAuthClientInformationMixed | undefined {
    return this.registeredClient;
  }

  saveClientInformation(clientInformation: OAuthClientInformationMixed): void {
    this.registeredClient = clientInformation;
  }

  tokens(): OAuthTokens | undefined {
    return this.exchangedTokens;
  }

  saveTokens(tokens: OAuthTokens): void {
    this.exchangedTokens = tokens;
  }

  redirectToAuthorization(authorizationUrl: URL): void {
    this.capturedAuthorizationUrl = authorizationUrl;
  }

  /** The SDK calls this after discovery — the one place the token endpoint surfaces to the client. */
  saveDiscoveryState(state: OAuthDiscoveryState): void {
    this.discoveredTokenEndpoint = state.authorizationServerMetadata?.token_endpoint;
  }

  saveCodeVerifier(codeVerifier: string): void {
    this.pkceCodeVerifier = codeVerifier;
  }

  codeVerifier(): string {
    if (this.pkceCodeVerifier === undefined) {
      throw new Error("no PKCE verifier was saved before the code exchange");
    }
    return this.pkceCodeVerifier;
  }

  /** Round 1's residue — what the pending entry must carry into round 2. */
  pendingSeed(): AuthorizationFlowSeed {
    if (this.registeredClient === undefined || this.pkceCodeVerifier === undefined) {
      throw new Error("the authorization round ended without a registered client or PKCE verifier");
    }
    return { clientInformation: this.registeredClient, codeVerifier: this.pkceCodeVerifier };
  }

  /** Round 2's result — the mcp `StoredCredential` to deposit, once `auth(...)` reported AUTHORIZED. The
   *  token endpoint discovered during the flow is persisted so the core refreshes without re-discovery;
   *  `expiresAt` is stamped from the grant's `expires_in` against `now`. */
  credential(resourceUrl: string, now: number): StoredCredential {
    if (this.exchangedTokens === undefined || this.registeredClient === undefined) {
      throw new Error("the token exchange completed without tokens or client information");
    }
    const tokens = this.exchangedTokens;
    return {
      profile: "mcp",
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token ?? null,
      expiresAt: tokens.expires_in === undefined ? null : now + tokens.expires_in * 1000,
      // Empty only if discovery somehow never fired (the SDK always calls saveDiscoveryState before the
      // code exchange); then the first in-core refresh re-discovers and backfills it.
      tokenEndpoint: this.discoveredTokenEndpoint ?? "",
      scopes: tokens.scope === undefined ? [] : tokens.scope.split(" ").filter((s) => s !== ""),
      clientInformation: this.registeredClient,
      resourceUrl,
    };
  }
}

/** The redirect's query parameters as the callback route hands them over (absent stays undefined). */
export interface AuthorizationCallbackQuery {
  code: string | undefined;
  state: string | undefined;
  error: string | undefined;
  errorDescription: string | undefined;
}

/** How one callback hit ended — what the route renders as the user-facing HTML page. */
export type AuthorizationCallbackOutcome =
  | { kind: "authorized"; name: string }
  | { kind: "failed"; reason: string };

export interface AuthorizationFlow {
  /** Start a flow for a credential by name — the proactive login endpoint. The acquisition profile is
   *  decided here: a `url` present → the mcp profile; absent → the configured profile (400 if no client is
   *  registered). Returns the authorization URL to open. */
  startForCredential(
    projectId: string,
    name: string,
    url: string | undefined,
  ): Promise<{ authorizationUrl: string }>;
  /** Start a flow from an open authorize escalation — the escalation-driven login. A thin derivation:
   *  read `{ name, url? }` off the escalation argument and call `startForCredential`. 404 when the
   *  escalation is not open; 409 when it is not an authorize escalation. */
  startFromEscalation(
    projectId: string,
    escalationId: string,
  ): Promise<{ authorizationUrl: string }>;
  handleCallback(query: AuthorizationCallbackQuery): Promise<AuthorizationCallbackOutcome>;
}

export function createAuthorizationFlow(
  dependencies: AuthorizationFlowDependencies,
): AuthorizationFlow {
  const pending = new Map<string, PendingAuthorizationFlow>();
  const callbackUrl = `${dependencies.publicUrl}/oauth/callback`;

  /** Lazy expiry: swept on every entry into the service, so no timer owns the map's lifetime. */
  function sweepExpiredFlows(): void {
    const now = dependencies.now();
    for (const [state, entry] of pending) {
      if (entry.expiresAt <= now) pending.delete(state);
    }
  }

  /** Restarting a login for a (project, name) supersedes: at most one redeemable flow per name, so an
   *  abandoned authorization URL dies the moment a new one is minted rather than staying independently
   *  redeemable until its TTL. */
  function replacePending(
    projectId: string,
    name: string,
    state: string,
    entry: PendingAuthorizationFlow,
  ): void {
    for (const [previousState, previous] of pending) {
      if (previous.projectId === projectId && previous.name === name) pending.delete(previousState);
    }
    pending.set(state, entry);
  }

  /** Round 1, mcp profile: discovery + registration + PKCE through the SDK orchestrator. */
  async function startMcp(projectId: string, name: string, url: string): Promise<string> {
    const state = randomUUID();
    const provider = new AuthorizationFlowProvider(callbackUrl, state, null);
    const firstRound = await auth(provider, { serverUrl: url });
    // With this provider — no stored tokens, a redirect URL present — the SDK's orchestrator always ends
    // round 1 at `redirectToAuthorization`; AUTHORIZED here would mean the orchestrator's contract changed
    // under us, so fail loudly rather than answer an escalation off a token set of unknown provenance.
    if (firstRound !== "REDIRECT" || provider.capturedAuthorizationUrl === null) {
      throw new Error("the authorization flow ended without producing an authorization URL");
    }
    const seed = provider.pendingSeed();
    replacePending(projectId, name, state, {
      profile: "mcp",
      projectId,
      name,
      url,
      codeVerifier: seed.codeVerifier,
      clientInformation: seed.clientInformation,
      expiresAt: dependencies.now() + AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS,
    });
    return provider.capturedAuthorizationUrl.toString();
  }

  /** Round 1, configured profile: a plain OAuth 2.1 authorization-code + PKCE request against the
   *  registered endpoints. No discovery, no registration — the endpoints are explicit. */
  async function startConfigured(projectId: string, name: string): Promise<string> {
    const config = await dependencies.loadClientConfig(projectId, name);
    if (config === null) {
      throw new BadRequestError(
        `no OAuth client named "${name}" is registered for this project; register one first`,
      );
    }
    const state = randomUUID();
    const codeVerifier = randomBytes(32).toString("base64url");
    const codeChallenge = createHash("sha256").update(codeVerifier).digest("base64url");
    const authorizationUrl = new URL(config.authorizeEndpoint);
    authorizationUrl.searchParams.set("response_type", "code");
    authorizationUrl.searchParams.set("client_id", config.clientId);
    authorizationUrl.searchParams.set("redirect_uri", callbackUrl);
    authorizationUrl.searchParams.set("state", state);
    authorizationUrl.searchParams.set("code_challenge", codeChallenge);
    authorizationUrl.searchParams.set("code_challenge_method", "S256");
    if (config.scopes.length > 0) {
      authorizationUrl.searchParams.set("scope", config.scopes.join(" "));
    }
    // The registered extra parameters (provider-specific data — Google's `access_type=offline` +
    // `prompt=consent`, without which no refresh token is issued) append AFTER the standard ones, and a
    // STANDARD parameter wins on a name collision: the standard set carries the flow's security material
    // (the callback capability in `redirect_uri` / `state`, the PKCE pair) and its protocol identity
    // (`response_type`, `client_id`, and a configured `scope`), so registry data must never override it —
    // a colliding entry is ignored, not merged and not appended as a duplicate key.
    for (const [key, value] of Object.entries(config.authorizationParameters)) {
      if (!authorizationUrl.searchParams.has(key)) authorizationUrl.searchParams.set(key, value);
    }
    replacePending(projectId, name, state, {
      profile: "configured",
      projectId,
      name,
      codeVerifier,
      tokenEndpoint: config.tokenEndpoint,
      clientId: config.clientId,
      clientSecret: config.clientSecret,
      scopes: config.scopes,
      expiresAt: dependencies.now() + AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS,
    });
    return authorizationUrl.toString();
  }

  /** Round 2, configured profile: exchange the code at the registered token endpoint (client_secret_basic
   *  when the client is confidential; PKCE always) into a `configured` `StoredCredential`. */
  async function exchangeConfiguredCode(
    entry: Extract<PendingAuthorizationFlow, { profile: "configured" }>,
    code: string,
    now: number,
  ): Promise<StoredCredential> {
    const params = new URLSearchParams({
      grant_type: "authorization_code",
      code,
      redirect_uri: callbackUrl,
      code_verifier: entry.codeVerifier,
    });
    const headers = new Headers({
      "Content-Type": "application/x-www-form-urlencoded",
      Accept: "application/json",
    });
    if (entry.clientSecret !== null) {
      headers.set("Authorization", `Basic ${btoa(`${entry.clientId}:${entry.clientSecret}`)}`);
    } else {
      params.set("client_id", entry.clientId);
    }
    const response = await fetch(entry.tokenEndpoint, { method: "POST", headers, body: params });
    if (!response.ok) {
      throw new Error(`the token endpoint returned HTTP ${response.status}`);
    }
    const tokens = OAuthTokensSchema.parse(await response.json());
    return {
      profile: "configured",
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token ?? null,
      expiresAt: tokens.expires_in === undefined ? null : now + tokens.expires_in * 1000,
      tokenEndpoint: entry.tokenEndpoint,
      scopes:
        tokens.scope === undefined
          ? entry.scopes
          : tokens.scope.split(" ").filter((scope) => scope !== ""),
      clientName: entry.name,
    };
  }

  /** The profile-independent completion: deposit the credential and answer EVERY open authorize escalation
   *  of the project waiting on this credential name — one rule: "when a credential becomes usable, every ask
   *  waiting on it is answered". Zero waiting escalations is fine (a proactive login is a pure deposit).
   *  Every failure is a value (the route renders it as a small HTML page). */
  async function depositAndAnswer(
    projectId: string,
    name: string,
    credential: StoredCredential,
  ): Promise<AuthorizationCallbackOutcome> {
    try {
      await dependencies.depositCredential(projectId, name, credential);
      const open = await dependencies.listOpenEscalations(projectId);
      for (const candidate of open) {
        if (candidate.request !== OAUTH_AUTHORIZE_REQUEST) continue;
        const waitingOn = oauthAuthorizeArgumentOf(candidate.argument);
        if (waitingOn === null || waitingOn.name !== name) continue;
        // Best-effort per row: the deposit above is already durable, so an escalation that settled in the
        // meantime (answered by a concurrent flow, or its run cancelled) needs nothing from us — losing one
        // ack must not fail the page or the other acks. But a TRANSIENT failure leaves a run parked behind
        // an "Authorized" page, so it is logged loudly for the operator.
        try {
          await dependencies.answerEscalation(projectId, candidate.id);
        } catch (error) {
          dependencies.warn(
            "an open authorize escalation could not be answered after its credential was deposited",
            {
              projectId,
              escalationId: candidate.id,
              credentialName: name,
              error: messageOf(error),
            },
          );
        }
      }
    } catch (error) {
      return {
        kind: "failed",
        reason:
          "the authorization succeeded but depositing the credential " +
          `(or finding its waiting runs) failed: ${messageOf(error)}`,
      };
    }
    return { kind: "authorized", name };
  }

  async function startForCredential(
    projectId: string,
    name: string,
    url: string | undefined,
  ): Promise<{ authorizationUrl: string }> {
    sweepExpiredFlows();
    const authorizationUrl =
      url !== undefined
        ? await startMcp(projectId, name, url)
        : await startConfigured(projectId, name);
    return { authorizationUrl };
  }

  async function startFromEscalation(
    projectId: string,
    escalationId: string,
  ): Promise<{ authorizationUrl: string }> {
    const escalation = await dependencies.loadOpenEscalation(projectId, escalationId);
    if (escalation === undefined) {
      throw new NotFoundError(`Escalation ${escalationId} not found (or already answered).`);
    }
    if (escalation.request !== OAUTH_AUTHORIZE_REQUEST) {
      throw new ConflictError(
        `Escalation ${escalationId} is not an OAuth authorization request (its request is ` +
          `"${escalation.request}"); answer it through the ordinary answer endpoint.`,
      );
    }
    const argument = oauthAuthorizeArgumentOf(escalation.argument);
    if (argument === null) {
      throw new ConflictError(
        `Escalation ${escalationId} carries no readable credential name to authorize against.`,
      );
    }
    return startForCredential(projectId, argument.name, argument.url ?? undefined);
  }

  async function handleCallback(
    query: AuthorizationCallbackQuery,
  ): Promise<AuthorizationCallbackOutcome> {
    sweepExpiredFlows();
    if (query.state === undefined) {
      return { kind: "failed", reason: "the redirect carried no state parameter" };
    }
    const entry = pending.get(query.state);
    if (entry === undefined) {
      return {
        kind: "failed",
        reason:
          "this authorization link is unknown, expired, or already used; " +
          "restart the authorization from the escalation or the credentials page",
      };
    }
    // Single-use either way: a failed exchange is restarted from the escalation / credentials page, never
    // replayed from a half-dead entry.
    pending.delete(query.state);
    if (query.error !== undefined) {
      const description = query.errorDescription === undefined ? "" : `: ${query.errorDescription}`;
      return {
        kind: "failed",
        reason: `the identity provider refused the authorization (${query.error}${description})`,
      };
    }
    if (query.code === undefined || query.code === "") {
      return { kind: "failed", reason: "the redirect carried no authorization code" };
    }

    let credential: StoredCredential;
    try {
      credential =
        entry.profile === "mcp"
          ? await exchangeMcpCode(entry, query.state, query.code)
          : await exchangeConfiguredCode(entry, query.code, dependencies.now());
    } catch (error) {
      return { kind: "failed", reason: `the token exchange failed: ${messageOf(error)}` };
    }
    // The deposit/answer half must also fail as a VALUE (the state is already burned, so an exception here
    // would surface as a bare 500 instead of the contracted HTML card).
    return depositAndAnswer(entry.projectId, entry.name, credential);
  }

  /** Round 2, mcp profile: the SDK orchestrator exchanges the code (its own discovery + registration seeded
   *  from round 1) and reports AUTHORIZED. */
  async function exchangeMcpCode(
    entry: Extract<PendingAuthorizationFlow, { profile: "mcp" }>,
    state: string,
    code: string,
  ): Promise<StoredCredential> {
    const provider = new AuthorizationFlowProvider(callbackUrl, state, {
      clientInformation: entry.clientInformation,
      codeVerifier: entry.codeVerifier,
    });
    const secondRound = await auth(provider, { serverUrl: entry.url, authorizationCode: code });
    if (secondRound !== "AUTHORIZED") {
      throw new Error("the token exchange did not authorize");
    }
    return provider.credential(entry.url, dependencies.now());
  }

  return { startForCredential, startFromEscalation, handleCallback };
}
