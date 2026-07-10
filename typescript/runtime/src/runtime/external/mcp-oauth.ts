// OAuth support for the mcp transport's outbound side. A program never handles token material: it
// names a CREDENTIAL (`mcp.oauth(name = ...)`), established out-of-band by `katari mcp login` and
// stored as a project secret under the reserved env key `mcp.oauth.<name>`. This module holds the
// pieces around that contract: the credential's stored shape, the store port the host wires in (the
// facade implements it over the env service), and the non-interactive `OAuthClientProvider` the SDK
// transport authenticates through — it loads tokens from the store, writes refreshed tokens back,
// and REFUSES anything interactive: reaching the authorization redirect means the credential is dead
// beyond refresh, which is the program-anticipatable `prelude.mcp.auth_error` (the fix is a human
// re-running login, not a retry — hence a type distinct from `server_error`).

import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import {
  type OAuthClientInformationMixed,
  OAuthClientInformationSchema,
  type OAuthClientMetadata,
  type OAuthTokens,
  OAuthTokensSchema,
} from "@modelcontextprotocol/sdk/shared/auth.js";

/** The reserved env-key namespace OAuth credentials live under. Reserving a dotted prefix (env keys
 *  are free-form) keeps credentials listable and deletable with the ordinary env tooling while making
 *  collisions with user keys deliberate rather than accidental. */
export function mcpOAuthEnvKey(name: string): string {
  return `mcp.oauth.${name}`;
}

/** One stored OAuth credential — exactly what `katari mcp login` emits and the runtime consumes:
 *  the token set, the (dynamically registered) client the tokens belong to, and the resource url the
 *  flow ran against (kept for the operator; token refresh rediscovers endpoints from the live server). */
export interface McpOAuthCredential {
  tokens: OAuthTokens;
  clientInformation: OAuthClientInformationMixed;
  resourceUrl: string;
}

/** The credential store port the transport reaches OAuth credentials through, keyed by credential
 *  NAME (never token material). `save` is the refresh write-back: a rotated token set must outlive
 *  the process, or every restart would burn the refresh token's single use. */
export interface McpCredentialStore {
  load(name: string): Promise<McpOAuthCredential | null>;
  save(name: string, credential: McpOAuthCredential): Promise<void>;
}

/** The failure that must surface as the typed `prelude.mcp.auth_error` throw (not `server_error`):
 *  the named credential is missing, undecodable, or expired beyond refresh. The transport's dispatch
 *  catch tells it apart by class, so no message-string sniffing is involved. */
export class McpAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "McpAuthError";
  }
}

/** Decode a stored credential's JSON text. The store is written by our own CLI, so a malformed blob
 *  is configuration damage, not program error — still `McpAuthError`, because the fix is the same:
 *  re-run `katari mcp login`. Validation reuses the SDK's own zod schemas, so "what the runtime
 *  accepts" cannot drift from "what the SDK's auth flow understands". */
export function decodeMcpOAuthCredential(name: string, raw: string): McpOAuthCredential {
  try {
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new Error("not a credential object");
    }
    const candidate: { tokens?: unknown; clientInformation?: unknown; resourceUrl?: unknown } =
      parsed;
    if (typeof candidate.resourceUrl !== "string") {
      throw new Error("missing resourceUrl");
    }
    return {
      tokens: OAuthTokensSchema.parse(candidate.tokens),
      // The base client-information schema keeps what runtime auth needs (client_id + secret and
      // their expiries) and strips the registration metadata a `Full` blob additionally carries.
      clientInformation: OAuthClientInformationSchema.parse(candidate.clientInformation),
      resourceUrl: candidate.resourceUrl,
    };
  } catch {
    throw new McpAuthError(
      `the stored OAuth credential "${name}" is unreadable (not the { tokens, clientInformation, resourceUrl } ` +
        `blob \`katari mcp login\` writes); re-run \`katari mcp login --name ${name}\``,
    );
  }
}

/** The runtime-side provider: tokens in, refreshed tokens out, nothing interactive. One instance per
 *  cached client (the SDK provider contract is per-server "session"). The credential is loaded once
 *  up front (see `loadStoredCredential`) so a missing credential fails as `auth_error` BEFORE any
 *  network I/O; refresh write-back goes through the same store the login command wrote. */
export class StoredMcpOAuthProvider implements OAuthClientProvider {
  private credential: McpOAuthCredential;

  constructor(
    private readonly name: string,
    private readonly store: McpCredentialStore,
    initial: McpOAuthCredential,
  ) {
    this.credential = initial;
  }

  /** No redirect target exists server-side; `undefined` marks the flow non-interactive to the SDK. */
  get redirectUrl(): undefined {
    return undefined;
  }

  /** Only consulted for dynamic registration, which this provider never performs (the client was
   *  registered at login); minimal but well-formed metadata in case a server inspects it. */
  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "katari-runtime",
      redirect_uris: [],
      grant_types: ["refresh_token"],
      token_endpoint_auth_method: "none",
    };
  }

  clientInformation(): OAuthClientInformationMixed {
    return this.credential.clientInformation;
  }

  async saveClientInformation(clientInformation: OAuthClientInformationMixed): Promise<void> {
    this.credential = { ...this.credential, clientInformation };
    await this.store.save(this.name, this.credential);
  }

  tokens(): OAuthTokens {
    return this.credential.tokens;
  }

  async saveTokens(tokens: OAuthTokens): Promise<void> {
    this.credential = { ...this.credential, tokens };
    await this.store.save(this.name, this.credential);
  }

  /** Reaching the interactive step means refresh failed (or the server revoked the grant): the
   *  credential is dead beyond what the runtime may do on its own. */
  redirectToAuthorization(): never {
    throw new McpAuthError(
      `the OAuth credential "${this.name}" was rejected and could not be refreshed; ` +
        `re-run \`katari mcp login --name ${this.name}\``,
    );
  }

  /** The PKCE steps belong to the interactive login flow, which never runs here. */
  saveCodeVerifier(): never {
    throw new McpAuthError(
      `the OAuth credential "${this.name}" requires an interactive login; run \`katari mcp login --name ${this.name}\``,
    );
  }

  codeVerifier(): never {
    throw new McpAuthError(
      `the OAuth credential "${this.name}" requires an interactive login; run \`katari mcp login --name ${this.name}\``,
    );
  }
}

/** Load the named credential, turning absence into the typed missing-credential failure. Split from
 *  the provider so the transport can fail a dispatch before constructing any SDK machinery. */
export async function loadStoredCredential(
  name: string,
  store: McpCredentialStore,
): Promise<McpOAuthCredential> {
  const credential = await store.load(name);
  if (credential === null) {
    throw new McpAuthError(
      `no OAuth credential named "${name}" is stored for this project; ` +
        `establish one with \`katari mcp login --url <server> --name ${name}\``,
    );
  }
  return credential;
}
