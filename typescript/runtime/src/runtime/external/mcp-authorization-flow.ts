// The runtime-hosted OAuth authorization flow (docs/2026-07-13-oauth-escalation.md §3): the interactive
// counterpart of a `prelude.mcp.authorize` escalation. The runtime is a continuously running server, so it
// hosts the whole OAuth 2.1 authorization-code + PKCE flow itself (discovery, dynamic client registration,
// code exchange) through the SDK's `auth(...)` orchestrator — the CLI and the console only open the URL
// this service mints. Two rounds, same structure as the retired `katari mcp login` helper:
//
//   round 1 (`start`)          — discovery + registration + PKCE; the provider captures the authorization
//                                URL instead of opening a browser, and the flow parks its state in memory
//                                under the minted OAuth `state` parameter;
//   round 2 (`handleCallback`) — the identity provider redirects the user's browser to the runtime's
//                                public `/oauth/callback`; the code is exchanged for tokens, the credential
//                                triple is deposited, and every open authorize escalation waiting on that
//                                credential name is answered (value null — token material never rides an
//                                answer).
//
// Flow state is deliberately IN-MEMORY with a short TTL: the durable thing is the escalation row, and a
// flow lost to a restart (or expiry) is restarted by pressing the button again. This service is the single
// owner of the pending entries — created at `start`, deleted at callback or expiry, never persisted.

import { randomUUID } from "node:crypto";
import { auth, type OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import type {
  OAuthClientInformationMixed,
  OAuthClientMetadata,
  OAuthTokens,
} from "@modelcontextprotocol/sdk/shared/auth.js";
import { ConflictError, NotFoundError } from "../../lib/errors.js";
import { messageOf } from "../actor/failure.js";
import type { Value } from "../value/types.js";
import { MCP_AUTHORIZE_REQUEST, type McpOAuthCredential } from "./mcp-oauth.js";

/** How long a started flow stays redeemable. Long enough for a human to authenticate at the identity
 *  provider; short enough that an abandoned `state` capability does not accumulate. */
export const AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS = 10 * 60 * 1000;

/** The `{ url, name }` payload of a `prelude.mcp.authorize` escalation, read out of its argument `Value`.
 *  Null when the argument does not carry the shape — the argument is runtime-synthesized (the mcp reactor
 *  raises it), so null means the row is unreadable, not that a user sent something odd. */
export function mcpAuthorizeArgumentOf(
  argument: Value | null,
): { url: string; name: string } | null {
  if (argument === null || argument.kind !== "record") return null;
  const url = argument.fields.url;
  const name = argument.fields.name;
  if (url === undefined || url.kind !== "string") return null;
  if (name === undefined || name.kind !== "string") return null;
  return { url: url.value, name: name.value };
}

/** One open escalation as the flow consumes it — just enough to recognise an authorize row and read its
 *  payload. Both escalation lookups the flow depends on speak this shape. */
export interface OpenEscalationCandidate {
  id: string;
  request: string;
  argument: Value | null;
}

/** What the flow needs from the host, injected so the service is testable against stubs and a fake
 *  identity provider without the database or the engine. */
export interface McpAuthorizationFlowDependencies {
  /** The public base URL this runtime is reachable at (`config.publicUrl`); the redirect_uri is minted
   *  as `<publicUrl>/oauth/callback` — the same one-address-one-knob as webhook / serve minted URLs. */
  publicUrl: string;
  /** One open escalation by id, or undefined when it does not exist (or was already answered). */
  loadOpenEscalation(
    projectId: string,
    escalationId: string,
  ): Promise<OpenEscalationCandidate | undefined>;
  /** Every open escalation of a project — the callback answers all authorize rows naming the credential. */
  listOpenEscalations(projectId: string): Promise<OpenEscalationCandidate[]>;
  /** Deposit the completed credential triple (the unconditional, generation-bumping upsert). */
  depositCredential(projectId: string, name: string, credential: McpOAuthCredential): Promise<void>;
  /** Answer one open escalation with value null (the resume signal; the raiser re-reads the store). */
  answerEscalation(projectId: string, escalationId: string): Promise<void>;
  /** Operator-facing logging for the one swallowed failure (a per-escalation answer that did not land
   *  after a successful deposit): the affected run stays parked behind an "Authorized" page, so the
   *  event must be visible somewhere other than the user's closed browser tab. */
  warn(message: string, context: Record<string, unknown>): void;
  /** The clock, injectable so tests can drive TTL expiry. */
  now(): number;
}

/** What round 2 must remember from round 1: the registered client and the PKCE verifier (plus who was
 *  waiting and where). Keyed by the minted `state` — the state parameter is the capability. */
interface PendingAuthorizationFlow {
  projectId: string;
  escalationId: string;
  name: string;
  url: string;
  codeVerifier: string;
  clientInformation: OAuthClientInformationMixed;
  expiresAt: number;
}

/** What round 2 seeds the provider with; round 1 starts from nothing (dynamic registration fills it). */
interface AuthorizationFlowSeed {
  clientInformation: OAuthClientInformationMixed;
  codeVerifier: string;
}

/** The in-memory provider driving the SDK's `auth(...)` orchestrator for one round. Interactive pieces
 *  are captured, not performed: `redirectToAuthorization` records the URL for the API response, and the
 *  registered client / PKCE verifier are read back into the pending-flow entry. */
class AuthorizationFlowProvider implements OAuthClientProvider {
  capturedAuthorizationUrl: URL | null = null;
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

  /** Round 2's result — the credential triple to deposit, once `auth(...)` reported AUTHORIZED. */
  credential(resourceUrl: string): McpOAuthCredential {
    if (this.exchangedTokens === undefined || this.registeredClient === undefined) {
      throw new Error("the token exchange completed without tokens or client information");
    }
    return {
      tokens: this.exchangedTokens,
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

export interface McpAuthorizationFlow {
  start(projectId: string, escalationId: string): Promise<{ authorizationUrl: string }>;
  handleCallback(query: AuthorizationCallbackQuery): Promise<AuthorizationCallbackOutcome>;
}

export function createMcpAuthorizationFlow(
  dependencies: McpAuthorizationFlowDependencies,
): McpAuthorizationFlow {
  const pending = new Map<string, PendingAuthorizationFlow>();
  const callbackUrl = `${dependencies.publicUrl}/oauth/callback`;

  /** Lazy expiry: swept on every entry into the service, so no timer owns the map's lifetime. */
  function sweepExpiredFlows(): void {
    const now = dependencies.now();
    for (const [state, entry] of pending) {
      if (entry.expiresAt <= now) pending.delete(state);
    }
  }

  return {
    /** Round 1: resolve the escalation to its `{ url, name }`, run discovery + registration + PKCE, and
     *  park the flow under a fresh `state`. 404 when the escalation is not open; 409 when it is open but
     *  not an authorize escalation (there is nothing OAuth-shaped to start). */
    async start(projectId, escalationId) {
      sweepExpiredFlows();
      const escalation = await dependencies.loadOpenEscalation(projectId, escalationId);
      if (escalation === undefined) {
        throw new NotFoundError(`Escalation ${escalationId} not found (or already answered).`);
      }
      if (escalation.request !== MCP_AUTHORIZE_REQUEST) {
        throw new ConflictError(
          `Escalation ${escalationId} is not an OAuth authorization request (its request is ` +
            `"${escalation.request}"); answer it through the ordinary answer endpoint.`,
        );
      }
      const argument = mcpAuthorizeArgumentOf(escalation.argument);
      if (argument === null) {
        throw new ConflictError(
          `Escalation ${escalationId} carries no readable { url, name } payload to authorize against.`,
        );
      }

      const state = randomUUID();
      const provider = new AuthorizationFlowProvider(callbackUrl, state, null);
      const firstRound = await auth(provider, { serverUrl: argument.url });
      // With this provider — no stored tokens, a redirect URL present — the SDK's orchestrator always
      // ends round 1 at `redirectToAuthorization`; AUTHORIZED here would mean the orchestrator's
      // contract changed under us, so fail loudly rather than answer an escalation off a token set of
      // unknown provenance.
      if (firstRound !== "REDIRECT" || provider.capturedAuthorizationUrl === null) {
        throw new Error("the authorization flow ended without producing an authorization URL");
      }
      // Restarting supersedes: one escalation holds at most one redeemable flow, so an abandoned
      // authorization URL dies the moment a new one is minted instead of staying independently
      // redeemable until its TTL.
      for (const [previousState, previousEntry] of pending) {
        if (previousEntry.projectId === projectId && previousEntry.escalationId === escalationId) {
          pending.delete(previousState);
        }
      }
      const seed = provider.pendingSeed();
      pending.set(state, {
        projectId,
        escalationId,
        name: argument.name,
        url: argument.url,
        codeVerifier: seed.codeVerifier,
        clientInformation: seed.clientInformation,
        expiresAt: dependencies.now() + AUTHORIZATION_FLOW_TIME_TO_LIVE_MILLISECONDS,
      });
      return { authorizationUrl: provider.capturedAuthorizationUrl.toString() };
    },

    /** Round 2: redeem the `state` capability, exchange the code, deposit the triple, and answer every
     *  open authorize escalation of the project waiting on this credential name — one rule: "when a
     *  credential becomes usable, every ask waiting on it is answered". Every failure is a value (the
     *  route renders it as a small HTML page), and the entry is single-use either way: a failed exchange
     *  is restarted from the escalation, never replayed from a half-dead entry. */
    async handleCallback(query) {
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
            "restart the authorization from the escalation",
        };
      }
      pending.delete(query.state);
      if (query.error !== undefined) {
        const description =
          query.errorDescription === undefined ? "" : `: ${query.errorDescription}`;
        return {
          kind: "failed",
          reason: `the identity provider refused the authorization (${query.error}${description})`,
        };
      }
      if (query.code === undefined || query.code === "") {
        return { kind: "failed", reason: "the redirect carried no authorization code" };
      }

      const provider = new AuthorizationFlowProvider(callbackUrl, query.state, {
        clientInformation: entry.clientInformation,
        codeVerifier: entry.codeVerifier,
      });
      let credential: McpOAuthCredential;
      try {
        const secondRound = await auth(provider, {
          serverUrl: entry.url,
          authorizationCode: query.code,
        });
        if (secondRound !== "AUTHORIZED") {
          return { kind: "failed", reason: "the token exchange did not authorize" };
        }
        credential = provider.credential(entry.url);
      } catch (error) {
        return { kind: "failed", reason: `the token exchange failed: ${messageOf(error)}` };
      }

      // The deposit/answer half must also fail as a VALUE: the state is already burned, so an exception
      // here would surface as a bare 500 instead of the contracted HTML card. The escalation is still
      // open either way — the failure page's restart hint mints a fresh flow.
      try {
        await dependencies.depositCredential(entry.projectId, entry.name, credential);
        const open = await dependencies.listOpenEscalations(entry.projectId);
        for (const candidate of open) {
          if (candidate.request !== MCP_AUTHORIZE_REQUEST) continue;
          const waitingOn = mcpAuthorizeArgumentOf(candidate.argument);
          if (waitingOn === null || waitingOn.name !== entry.name) continue;
          // Best-effort per row: the deposit above is already durable, so an escalation that settled in
          // the meantime (answered by a concurrent flow, or its run cancelled) needs nothing from us —
          // losing one ack must not fail the page or the other acks. But a TRANSIENT failure leaves a
          // run parked behind an "Authorized" page, so it is logged loudly for the operator.
          try {
            await dependencies.answerEscalation(entry.projectId, candidate.id);
          } catch (error) {
            dependencies.warn(
              "an open authorize escalation could not be answered after its credential was deposited",
              {
                projectId: entry.projectId,
                escalationId: candidate.id,
                credentialName: entry.name,
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
      return { kind: "authorized", name: entry.name };
    },
  };
}
