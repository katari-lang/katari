// The credentials core (docs/2026-07-14-credentials-core.md §1–§3): the profile-tagged credential store
// and the on-demand token resolution + refresh that every OAuth-protected consumer shares. A program
// never handles token material — it names a CREDENTIAL (`mcp.oauth(name = ...)` today), whose sealed
// value lives in the runtime's `credentials` table. This module owns the pieces around that contract that
// are PROFILE-INDEPENDENT: the stored shape, the store port the host wires in, the park signal a
// consumer raises when a credential cannot authenticate, and `resolveToken` — load the credential, hand
// back its access token while the stored clock says it is still valid, and otherwise run a plain OAuth 2.1
// `refresh_token` grant against the STORED token endpoint (no re-discovery) and write the rotation back
// under the compare-and-set generation. Refresh moving HERE (out of the SDK's per-connection auth
// provider) is the crux of the rebuild: the token endpoint persisted at acquisition is all the core needs.

import type { QualifiedName } from "@katari-lang/types";
import {
  discoverOAuthServerInfo,
  selectClientAuthMethod,
} from "@modelcontextprotocol/sdk/client/auth.js";
import {
  type OAuthClientInformationMixed,
  OAuthClientInformationSchema,
  type OAuthTokens,
  OAuthTokensSchema,
} from "@modelcontextprotocol/sdk/shared/auth.js";

/** The request an OAuth authorization park escalates as — runtime-synthesized like `prelude.panic` /
 *  `prelude.throw` (see `PANIC_REQUEST` / `THROW_REQUEST`), but a genuine user-facing request: it opens a
 *  durable escalation row, relays to the api root, and its answer (the value is ignored) resumes the
 *  parked operation. It appears in no IR row, so no user `handle` can catch it. Generalized from the
 *  prototype's `prelude.mcp.authorize`: "authorize this credential", whatever consumer needs it. */
export const OAUTH_AUTHORIZE_REQUEST = "prelude.oauth.authorize" as QualifiedName;

/** How far before the stored `expiresAt` a token is treated as due for refresh — a proactive margin so a
 *  refresh happens BEFORE the token expires under a call, avoiding the round-trip 401 that would otherwise
 *  park. ~60s covers clock skew and the request's own latency. */
const REFRESH_MARGIN_MILLISECONDS = 60_000;

/** The profile-independent core of a stored credential — everything past acquisition (expiry judgement,
 *  refresh grant, bearer injection) reads only these fields, so the profile discriminator matters just to
 *  how the refresh grant authenticates. */
interface StoredCredentialCore {
  /** The bearer token injected on the wire — the expiry SoT is `expiresAt`, not this opaque string. */
  accessToken: string;
  /** The refresh token, or `null` when the grant issued none (then an expired credential can only re-login). */
  refreshToken: string | null;
  /** Epoch milliseconds the access token expires at, or `null` when the grant declared no lifetime (then
   *  the token is used until the server rejects it — the reactive 401 park). */
  expiresAt: number | null;
  /** The OAuth token endpoint refresh POSTs to — persisted at acquisition so the core never re-discovers.
   *  Empty only for a credential migrated from the prototype triple, which re-discovers once (see
   *  `refreshGrant`) and writes the endpoint back so later refreshes skip discovery. */
  tokenEndpoint: string;
  /** The granted scopes (for the operator's read; not re-sent on refresh). */
  scopes: string[];
}

/** One stored credential — the sealed `value` of a `credentials` row (docs §1). Profile-tagged: the `mcp`
 *  profile's client is dynamically registered and its resource url comes from RFC 9728 discovery; the
 *  Phase 2 `configured` profile's client is an operator-registered `oauth_clients` row referenced by name
 *  (so a rotated client secret is picked up at refresh time — the credential stores no client secret of
 *  its own). The refresh grant is a plain OAuth 2.1 `refresh_token` POST either way; only the client
 *  authentication material differs by arm. */
export type StoredCredential =
  | (StoredCredentialCore & {
      profile: "mcp";
      /** The dynamically registered client the tokens belong to (client_id + optional secret) — the
       *  refresh grant authenticates as it. */
      clientInformation: OAuthClientInformationMixed;
      /** The RFC 9728 resource url the flow ran against — the refresh grant's `resource` indicator, and
       *  the discovery base for a migrated credential with no stored token endpoint. */
      resourceUrl: string;
    })
  | (StoredCredentialCore & {
      profile: "configured";
      /** The operator-registered `oauth_clients` row this credential authenticates as — looked up by name
       *  on every refresh (`CredentialStore.resolveConfiguredClient`), so a rotated client secret takes
       *  effect without re-authorizing. `tokenEndpoint` is always the registered endpoint (never empty). */
      clientName: string;
    });

/** A credential as read out of the store, paired with the integer `generation` of THAT stored version (a
 *  real column, bumped on every write). `resolveToken` captures the generation at load and echoes it back
 *  to `save`, which writes only while it still matches — a compare-and-set, so a token refresh never
 *  clobbers a credential a fresh authorization replaced under it. */
export interface LoadedCredential {
  credential: StoredCredential;
  generation: number;
}

/** An operator-registered OAuth client's authentication material, as a `configured` credential's refresh
 *  reads it from the `oauth_clients` registry: the `client_id`, and the `client_secret` when the client is
 *  confidential (`null` for a public client — a GENUINE absence, not a missing lookup). */
export interface ConfiguredClientCredentials {
  clientId: string;
  clientSecret: string | null;
}

/** The credential store port the core reaches credentials through, keyed by credential NAME (never token
 *  material). `save` is the refresh write-back: a rotated token set must outlive the process, or every
 *  restart would burn the refresh token's single use — but it is CONDITIONAL on the generation the caller
 *  loaded, resolving to whether the write took: a stale write (a refresh off a credential a re-authorization
 *  has since replaced) resolves `false` and leaves the newer record standing. The flow-completion writer
 *  upserts unconditionally, but through the repository directly — this port stays the engine-side seam.
 *  `resolveConfiguredClient` reaches the `oauth_clients` registry a `configured` credential's refresh
 *  authenticates as (read live so a rotated secret takes effect); it is never consulted for an `mcp`
 *  credential (whose client is embedded), and resolves `null` when the operator deleted the client — the
 *  refresh is then dead and the resolution parks for re-login. */
export interface CredentialStore {
  load(name: string): Promise<LoadedCredential | null>;
  save(name: string, credential: StoredCredential, expectedGeneration: number): Promise<boolean>;
  resolveConfiguredClient(clientName: string): Promise<ConfiguredClientCredentials | null>;
}

/** The park signal: the named credential cannot authenticate this operation without a human — it is
 *  missing, unreadable, or refresh-dead. Distinct by class (a consumer's dispatch catch tells it apart
 *  without message sniffing) from every program-anticipatable error: on the OAuth path it NEVER becomes a
 *  typed throw — the consumer escalates `prelude.oauth.authorize` and retries once the escalation is
 *  answered. Carries only the credential name the throw site knows; the `{ url }` the escalation shows is
 *  stamped by the consumer from its descriptor (the SDK's own errors carry neither). */
export class CredentialAuthorizationRequired extends Error {
  constructor(
    message: string,
    /** The stored credential's name — the identity the authorization must (re)establish. */
    readonly credentialName: string,
  ) {
    super(message);
    this.name = "CredentialAuthorizationRequired";
  }
}

/** Read one field off an unknown-typed object without a cast (structural narrowing only). */
function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Decode a stored credential's JSON text into the profile-tagged shape. The store is written by the
 *  runtime's own authorization flow, so a malformed blob is configuration damage, not program error —
 *  still the park signal, because the remedy is the same: a fresh interactive authorization. TWO shapes
 *  decode: the current profile-tagged object, and the prototype triple `{ tokens, clientInformation,
 *  resourceUrl }` a migrated row still holds (the 0013 migration copies the sealed value verbatim, so the
 *  profile is stamped HERE — a triple has no stored token endpoint, so it re-discovers once on first
 *  refresh). */
export function decodeStoredCredential(name: string, raw: string): StoredCredential {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!isObject(parsed)) throw new Error("not a credential object");
    // Dispatch on the stored `profile` tag: a `configured` credential (Phase 2) references its client by
    // name, an `mcp` credential embeds its dynamically registered client. A value with no tag is either the
    // current `mcp` shape (a string `accessToken`) or the migrated prototype triple (a `tokens` object).
    if (parsed.profile === "configured") return decodeConfiguredCredential(parsed);
    return typeof parsed.accessToken === "string"
      ? decodeCurrentCredential(parsed)
      : decodeMigratedTriple(parsed);
  } catch {
    throw new CredentialAuthorizationRequired(
      `the stored credential "${name}" is unreadable; a fresh authorization must replace it`,
      name,
    );
  }
}

/** Decode the current profile-tagged stored shape (validating the client information through the SDK's own
 *  schema, so "what the runtime accepts" cannot drift from "what a refresh grant understands"). */
function decodeCurrentCredential(source: Record<string, unknown>): StoredCredential {
  const { accessToken, refreshToken, expiresAt, tokenEndpoint, scopes, resourceUrl } = source;
  if (typeof accessToken !== "string") throw new Error("missing accessToken");
  if (typeof tokenEndpoint !== "string") throw new Error("missing tokenEndpoint");
  if (typeof resourceUrl !== "string") throw new Error("missing resourceUrl");
  return {
    profile: "mcp",
    accessToken,
    refreshToken: typeof refreshToken === "string" ? refreshToken : null,
    expiresAt: typeof expiresAt === "number" ? expiresAt : null,
    tokenEndpoint,
    scopes: Array.isArray(scopes) ? scopes.filter((scope) => typeof scope === "string") : [],
    clientInformation: OAuthClientInformationSchema.parse(source.clientInformation),
    resourceUrl,
  };
}

/** Decode the `configured` stored shape: a plain OAuth 2.1 credential referencing an operator-registered
 *  client by name. It embeds no client material (the refresh reads the `oauth_clients` registry live), so
 *  it carries only the tokens, the registered token endpoint, the scopes, and the client name. */
function decodeConfiguredCredential(source: Record<string, unknown>): StoredCredential {
  const { accessToken, refreshToken, expiresAt, tokenEndpoint, scopes, clientName } = source;
  if (typeof accessToken !== "string") throw new Error("missing accessToken");
  if (typeof tokenEndpoint !== "string") throw new Error("missing tokenEndpoint");
  if (typeof clientName !== "string") throw new Error("missing clientName");
  return {
    profile: "configured",
    accessToken,
    refreshToken: typeof refreshToken === "string" ? refreshToken : null,
    expiresAt: typeof expiresAt === "number" ? expiresAt : null,
    tokenEndpoint,
    scopes: Array.isArray(scopes) ? scopes.filter((scope) => typeof scope === "string") : [],
    clientName,
  };
}

/** Decode the prototype's `{ tokens, clientInformation, resourceUrl }` triple a migrated row still holds,
 *  stamping the `mcp` profile and flattening the token set. No token endpoint was stored then, so it stays
 *  empty and the first refresh re-discovers it (and writes the current shape back). `expiresAt` is unknown
 *  (the triple never persisted an issue time), so the token is used until the server rejects it. */
function decodeMigratedTriple(source: Record<string, unknown>): StoredCredential {
  if (typeof source.resourceUrl !== "string") throw new Error("missing resourceUrl");
  const tokens = OAuthTokensSchema.parse(source.tokens);
  return {
    profile: "mcp",
    accessToken: tokens.access_token,
    refreshToken: tokens.refresh_token ?? null,
    expiresAt: null,
    tokenEndpoint: "",
    scopes:
      tokens.scope === undefined ? [] : tokens.scope.split(" ").filter((scope) => scope !== ""),
    clientInformation: OAuthClientInformationSchema.parse(source.clientInformation),
    resourceUrl: source.resourceUrl,
  };
}

/** The current stored value from a rotated token set, carrying the (possibly re-discovered) token endpoint
 *  forward so a later refresh skips discovery. `expiresAt` is computed from the grant's `expires_in`. */
function credentialFromRefresh(
  base: StoredCredential,
  tokens: OAuthTokens,
  tokenEndpoint: string,
  now: number,
): StoredCredential {
  return {
    ...base,
    accessToken: tokens.access_token,
    // A grant often does not re-issue the refresh token (it stays single-use); keep the one we have.
    refreshToken: tokens.refresh_token ?? base.refreshToken,
    expiresAt: tokens.expires_in === undefined ? null : now + tokens.expires_in * 1000,
    tokenEndpoint,
    scopes:
      tokens.scope === undefined ? base.scopes : tokens.scope.split(" ").filter((s) => s !== ""),
  };
}

/** The outcome of resolving a credential to a usable bearer token. `needsAuthorize` is the park trigger the
 *  consumer turns into a `prelude.oauth.authorize` escalation. */
export type TokenResolution =
  | { kind: "token"; token: string }
  | { kind: "needsAuthorize"; name: string };

/** A refresh failure the grant itself pronounced: the token endpoint (or its discovery) said this refresh
 *  token will never work again — `invalid_grant` and its 4xx kin, or a server that advertises no token
 *  endpoint at all. Only THIS failure means "a human must re-authorize"; every other refresh failure (a
 *  network error, a token-endpoint 5xx) is transient and propagates out of `resolveToken`, so the
 *  consumer's ordinary error classification keeps it retryable instead of waking a human for an outage. */
class RefreshRefused extends Error {}

/** The refreshes currently in flight, one per (store, name) — concurrent resolutions of the same
 *  credential share ONE grant POST, because a rotated refresh token is often single-use: two racing
 *  refreshes would burn it twice and dead-end the loser. Cleared when the flight settles; keyed weakly by
 *  the store instance so a project actor's teardown drops its entries with the store. */
const inflightRefreshes = new WeakMap<CredentialStore, Map<string, Promise<TokenResolution>>>();

/** Resolve the named credential to a usable access token (docs §2). Load it; while the stored clock says
 *  it is still valid (with the proactive margin) hand back the access token; once due, run a
 *  `refresh_token` grant against the STORED token endpoint and write the rotation back under the
 *  compare-and-set generation. A missing credential, a missing refresh token, or a refresh the grant
 *  REFUSED all resolve to `needsAuthorize` — the one park-and-re-login trigger — while a transient refresh
 *  failure (network, token-endpoint 5xx) THROWS, so the consumer's error classification keeps it
 *  retryable. A refused write-back (a fresh authorization replaced the credential under the refresh) is
 *  not an error: the newer credential stands and the just-minted token is returned.
 *
 *  `rejectedToken` is the consumer's reactive hint: the server just answered 401 to this exact token. A
 *  token known to be rejected is treated as expired whatever the stored clock says — the valid-by-clock
 *  shortcut (including the no-known-expiry one) is skipped and the refresh branch runs, which is also how
 *  a migrated credential (no stored expiry, no stored endpoint) gets its first silent refresh and its
 *  token-endpoint backfill. A hint that no longer matches the STORED token means a fresh authorization
 *  (or another resolution's refresh) already replaced it — the replacement is served by the normal rules. */
export async function resolveToken(
  store: CredentialStore,
  name: string,
  rejectedToken?: string,
): Promise<TokenResolution> {
  const loaded = await store.load(name);
  if (loaded === null) return { kind: "needsAuthorize", name };
  const credential = loaded.credential;
  const knownRejected = rejectedToken !== undefined && rejectedToken === credential.accessToken;
  // Valid by clock (or a credential whose grant declared no lifetime, used until a 401 says otherwise) —
  // unless the server just proved the clock wrong by rejecting this very token.
  if (
    !knownRejected &&
    (credential.expiresAt === null ||
      Date.now() < credential.expiresAt - REFRESH_MARGIN_MILLISECONDS)
  ) {
    return { kind: "token", token: credential.accessToken };
  }
  if (credential.refreshToken === null) return { kind: "needsAuthorize", name };
  const flights = flightsOf(store);
  const inFlight = flights.get(name);
  if (inFlight !== undefined) return inFlight;
  const flight = refreshAndSave(store, name, loaded, credential.refreshToken).finally(() =>
    flights.delete(name),
  );
  flights.set(name, flight);
  return flight;
}

/** The per-name flight map of one store, created on first use. */
function flightsOf(store: CredentialStore): Map<string, Promise<TokenResolution>> {
  const existing = inflightRefreshes.get(store);
  if (existing !== undefined) return existing;
  const created = new Map<string, Promise<TokenResolution>>();
  inflightRefreshes.set(store, created);
  return created;
}

/** One refresh flight: run the grant, write the rotation back under the loaded generation, and resolve to
 *  the fresh token. A REFUSED grant resolves to `needsAuthorize` (refresh is dead — re-login); a transient
 *  failure rejects, propagating out of every resolution sharing this flight. */
async function refreshAndSave(
  store: CredentialStore,
  name: string,
  loaded: LoadedCredential,
  refreshToken: string,
): Promise<TokenResolution> {
  let refreshed: { tokens: OAuthTokens; tokenEndpoint: string };
  try {
    refreshed = await refreshGrant(store, loaded.credential, refreshToken);
  } catch (error) {
    if (error instanceof RefreshRefused) return { kind: "needsAuthorize", name };
    throw error;
  }
  const rotated = credentialFromRefresh(
    loaded.credential,
    refreshed.tokens,
    refreshed.tokenEndpoint,
    Date.now(),
  );
  // The write-back is a compare-and-set: a `false` means a fresh authorization replaced the credential
  // under this refresh, so the newer record stands — but the token we just minted is still valid to use.
  await store.save(name, rotated, loaded.generation);
  return { kind: "token", token: rotated.accessToken };
}

/** Run one OAuth 2.1 `refresh_token` grant against the credential's STORED token endpoint — a plain
 *  token-endpoint POST, the profile-independent grant (docs §2). Only the client authentication material
 *  differs by profile: an `mcp` credential authenticates as its embedded dynamically registered client
 *  (the SDK's own method selection — a public mcp client puts its `client_id` in the body) and carries the
 *  RFC 8707 resource indicator, discovering its endpoint once when migrated from the prototype triple; a
 *  `configured` credential authenticates as its operator-registered client, read LIVE from the registry so
 *  a rotated secret takes effect (a deleted client — or a stored endpoint gone missing — is `RefreshRefused`,
 *  a re-login). A 4xx from the endpoint is `RefreshRefused` (the grant is dead); anything else that fails —
 *  network, 5xx, an unparseable success body — throws plain and is treated as transient by the caller. */
async function refreshGrant(
  store: CredentialStore,
  credential: StoredCredential,
  refreshToken: string,
): Promise<{ tokens: OAuthTokens; tokenEndpoint: string }> {
  const params = new URLSearchParams({ grant_type: "refresh_token", refresh_token: refreshToken });
  const headers = new Headers({
    "Content-Type": "application/x-www-form-urlencoded",
    Accept: "application/json",
  });
  let tokenEndpoint: string;
  switch (credential.profile) {
    case "mcp": {
      tokenEndpoint =
        credential.tokenEndpoint !== ""
          ? credential.tokenEndpoint
          : await discoverTokenEndpoint(credential.resourceUrl);
      applyClientAuthentication(credential.clientInformation, headers, params);
      // RFC 8707 resource indicator — the same one the acquisition flow authorized against.
      if (credential.resourceUrl !== "") params.set("resource", credential.resourceUrl);
      break;
    }
    case "configured": {
      if (credential.tokenEndpoint === "") {
        throw new RefreshRefused("a configured credential has no stored token endpoint");
      }
      tokenEndpoint = credential.tokenEndpoint;
      const client = await store.resolveConfiguredClient(credential.clientName);
      if (client === null) {
        throw new RefreshRefused(
          `the registered client "${credential.clientName}" no longer exists`,
        );
      }
      applyConfiguredClientAuthentication(client, headers, params);
      break;
    }
  }
  const response = await fetch(tokenEndpoint, { method: "POST", headers, body: params });
  if (!response.ok) {
    if (response.status >= 400 && response.status < 500) {
      throw new RefreshRefused(`the token endpoint refused the refresh (HTTP ${response.status})`);
    }
    throw new Error(`the token endpoint failed (HTTP ${response.status})`);
  }
  const tokens = OAuthTokensSchema.parse(await response.json());
  return { tokens, tokenEndpoint };
}

/** Discover the token endpoint for a migrated credential (RFC 9728), so its first in-core refresh matches
 *  what the SDK provider used to re-discover. A reachable server that advertises no token endpoint leaves
 *  the credential un-refreshable for good (`RefreshRefused` — the caller parks); a discovery the network
 *  failed propagates as transient. */
async function discoverTokenEndpoint(resourceUrl: string): Promise<string> {
  const info = await discoverOAuthServerInfo(resourceUrl);
  const endpoint = info.authorizationServerMetadata?.token_endpoint;
  if (endpoint === undefined) {
    throw new RefreshRefused(`no token endpoint discoverable for ${resourceUrl}`);
  }
  return endpoint;
}

/** Apply the registered client's authentication to a token request, dispatching on the SDK's own method
 *  selection (RFC 8414 §2 defaults when the server metadata is absent): HTTP Basic for a confidential
 *  client, or the `client_id` in the body for a public one (the mcp DCR case). Mirrors the SDK's internal
 *  `applyClientAuthentication` so an in-core refresh authenticates exactly as the SDK's did. */
function applyClientAuthentication(
  clientInformation: OAuthClientInformationMixed,
  headers: Headers,
  params: URLSearchParams,
): void {
  const clientId = clientInformation.client_id;
  const clientSecret = clientInformation.client_secret;
  switch (selectClientAuthMethod(clientInformation, [])) {
    case "client_secret_basic":
      if (clientSecret !== undefined) {
        headers.set("Authorization", `Basic ${btoa(`${clientId}:${clientSecret}`)}`);
      }
      return;
    case "client_secret_post":
      params.set("client_id", clientId);
      if (clientSecret !== undefined) params.set("client_secret", clientSecret);
      return;
    case "none":
      params.set("client_id", clientId);
      return;
  }
}

/** Apply an operator-registered `configured` client's authentication to a token request: HTTP Basic
 *  (`client_secret_basic`) when the client is confidential, or the `client_id` in the body when it is a
 *  public client (a `null` secret — a genuine absence). Matches the acquisition flow's code exchange, so a
 *  refresh authenticates exactly as the original authorization did. */
function applyConfiguredClientAuthentication(
  client: ConfiguredClientCredentials,
  headers: Headers,
  params: URLSearchParams,
): void {
  if (client.clientSecret !== null) {
    headers.set("Authorization", `Basic ${btoa(`${client.clientId}:${client.clientSecret}`)}`);
    return;
  }
  params.set("client_id", client.clientId);
}
