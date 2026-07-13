// OAuth support for the mcp transport's outbound side. A program never handles token material: it
// names a CREDENTIAL (`mcp.oauth(name = ...)`), whose token triple lives in the runtime's dedicated
// credential store (the `mcp_credentials` table — see docs/2026-07-13-oauth-escalation.md §2). This
// module holds the pieces around that contract: the credential's stored shape, the store port the host
// wires in, and the non-interactive `OAuthClientProvider` the SDK transport authenticates through — it
// loads tokens from the store, writes refreshed tokens back, and REFUSES anything interactive: reaching
// the authorization redirect means the credential is dead beyond refresh. That refusal is NOT an error a
// program handles — it is `McpAuthorizationRequired`, the park signal the mcp reactor turns into a
// `prelude.mcp.authorize` escalation: the call pauses, a human authorizes, and the answering ack retries.

import type { QualifiedName } from "@katari-lang/types";
import type { OAuthClientProvider } from "@modelcontextprotocol/sdk/client/auth.js";
import {
  type OAuthClientInformationMixed,
  OAuthClientInformationSchema,
  type OAuthClientMetadata,
  type OAuthTokens,
  OAuthTokensSchema,
} from "@modelcontextprotocol/sdk/shared/auth.js";

/** The request an oauth authorization park escalates as — runtime-synthesized like `prelude.panic` /
 *  `prelude.throw` (see `PANIC_REQUEST` / `THROW_REQUEST`), but a genuine user-facing request: it opens a
 *  durable escalation row, relays to the api root, and its answer (the value is ignored) resumes the
 *  parked mcp operation. It appears in no IR row, so no user `handle` can catch it. */
export const MCP_AUTHORIZE_REQUEST = "prelude.mcp.authorize" as QualifiedName;

/** One stored OAuth credential — exactly what the runtime-hosted authorization flow deposits and the
 *  runtime consumes: the token set, the (dynamically registered) client the tokens belong to, and the
 *  resource url the flow ran against (kept for the operator; token refresh rediscovers endpoints from
 *  the live server). */
export interface McpOAuthCredential {
  tokens: OAuthTokens;
  clientInformation: OAuthClientInformationMixed;
  resourceUrl: string;
}

/** A credential as read out of the store, paired with the integer `generation` of THAT stored version
 *  (a real column, bumped on every write). The provider captures the generation at load and echoes it
 *  back to `save`, which writes only while it still matches — a compare-and-set, so a token refresh never
 *  clobbers a credential a fresh authorization replaced under it. */
export interface LoadedMcpOAuthCredential {
  credential: McpOAuthCredential;
  generation: number;
}

/** The credential store port the transport reaches OAuth credentials through, keyed by credential
 *  NAME (never token material). `save` is the refresh write-back: a rotated token set must outlive
 *  the process, or every restart would burn the refresh token's single use — but it is CONDITIONAL on the
 *  generation the caller loaded, resolving to whether the write took: a stale write (a warm provider
 *  refreshing off a credential a re-authorization has since replaced) resolves `false` and leaves the
 *  newer record standing. The flow-completion writer upserts unconditionally, but through the repository
 *  directly — this port stays the engine-side seam. */
export interface McpCredentialStore {
  load(name: string): Promise<LoadedMcpOAuthCredential | null>;
  save(name: string, credential: McpOAuthCredential, expectedGeneration: number): Promise<boolean>;
}

/** The park signal: the named credential cannot authenticate this operation without a human — it is
 *  missing, unreadable, or the server rejected it beyond what a refresh can fix. Distinct by class (the
 *  transport's dispatch catch tells it apart without message sniffing) from every program-anticipatable
 *  error: on the oauth path it NEVER becomes a typed throw — the mcp reactor escalates
 *  `prelude.mcp.authorize` and retries the operation once the escalation is answered. The `{ url, name }`
 *  the escalation carries is stamped at the transport's classification boundary from the descriptor (its
 *  source of truth — the SDK's own `UnauthorizedError` carries neither), so this class carries only the
 *  credential name the throw site knows. */
export class McpAuthorizationRequired extends Error {
  constructor(
    message: string,
    /** The stored credential's name — the identity the authorization must (re)establish. */
    readonly credentialName: string,
  ) {
    super(message);
    this.name = "McpAuthorizationRequired";
  }
}

/** Decode a stored credential's JSON text. The store is written by the runtime's own authorization flow,
 *  so a malformed blob is configuration damage, not program error — still `McpAuthorizationRequired`,
 *  because the remedy is the same: a fresh interactive authorization. Validation reuses the SDK's own zod
 *  schemas, so "what the runtime accepts" cannot drift from "what the SDK's auth flow understands". */
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
    throw new McpAuthorizationRequired(
      `the stored OAuth credential "${name}" is unreadable (not the { tokens, clientInformation, resourceUrl } ` +
        `triple the authorization flow deposits); a fresh authorization must replace it`,
      name,
    );
  }
}

/** The runtime-side provider: tokens in, refreshed tokens out, nothing interactive. One instance per
 *  cached client (the SDK provider contract is per-server "session"). It reads the credential THROUGH the
 *  store on every `tokens()` / `clientInformation()` (an mcp call is network I/O anyway, so one store read
 *  is cheap) — so a warm provider the transport cached across a re-authorization never serves a stale
 *  credential — and it remembers the generation it read so a refresh write-back refuses to overwrite a
 *  credential replaced under it. */
export class StoredMcpOAuthProvider implements OAuthClientProvider {
  /** The credential + its generation as last read through the store, captured so `saveTokens` /
   *  `saveClientInformation` can compare-and-set against it. */
  private loaded: LoadedMcpOAuthCredential | null = null;

  constructor(
    private readonly name: string,
    private readonly store: McpCredentialStore,
  ) {}

  /** A placeholder, never actually redirected to: the PKCE steps (`saveCodeVerifier`) throw before any
   *  redirect can happen. It must be non-`undefined` because the SDK reads an undefined `redirectUrl` as
   *  "non-interactive grant" and then SKIPS the refresh attempt entirely — with it defined, a 401 first
   *  tries the refresh grant (the one thing this provider may do alone) and only then reaches the
   *  interactive step, where the park signal fires. The out-of-band URN says what is true: no in-process
   *  redirect target exists (the real interactive flow is runtime-hosted, reached via the escalation). */
  get redirectUrl(): string {
    return "urn:ietf:wg:oauth:2.0:oob";
  }

  /** Only consulted for dynamic registration, which this provider never performs (the client was
   *  registered by the authorization flow); minimal but well-formed metadata in case a server inspects it. */
  get clientMetadata(): OAuthClientMetadata {
    return {
      client_name: "katari-runtime",
      redirect_uris: [],
      grant_types: ["refresh_token"],
      token_endpoint_auth_method: "none",
    };
  }

  /** Read the credential fresh from the store, remembering its generation. A vanished credential (deleted
   *  since, or never stored) is the park signal — the runtime cannot authorize on its own. */
  private async reload(): Promise<LoadedMcpOAuthCredential> {
    const record = await this.store.load(this.name);
    if (record === null) {
      throw new McpAuthorizationRequired(
        `the OAuth credential "${this.name}" is no longer stored; authorization is required`,
        this.name,
      );
    }
    this.loaded = record;
    return record;
  }

  async clientInformation(): Promise<OAuthClientInformationMixed> {
    return (await this.reload()).credential.clientInformation;
  }

  async saveClientInformation(clientInformation: OAuthClientInformationMixed): Promise<void> {
    const base = this.loaded ?? (await this.reload());
    // A refused write (a fresh authorization landed under this refresh) is not an error: the newer
    // credential stands, and the next use picks it up through the read-through `reload`.
    await this.store.save(this.name, { ...base.credential, clientInformation }, base.generation);
  }

  async tokens(): Promise<OAuthTokens> {
    return (await this.reload()).credential.tokens;
  }

  async saveTokens(tokens: OAuthTokens): Promise<void> {
    const base = this.loaded ?? (await this.reload());
    await this.store.save(this.name, { ...base.credential, tokens }, base.generation);
  }

  /** Reaching the interactive step means refresh failed (or the server revoked the grant): the
   *  credential is dead beyond what the runtime may do on its own — park and ask. */
  redirectToAuthorization(): never {
    throw new McpAuthorizationRequired(
      `the OAuth credential "${this.name}" was rejected and could not be refreshed; ` +
        `authorization is required`,
      this.name,
    );
  }

  /** The PKCE steps belong to the interactive authorization flow, which never runs here. */
  saveCodeVerifier(): never {
    throw new McpAuthorizationRequired(
      `the OAuth credential "${this.name}" requires an interactive authorization`,
      this.name,
    );
  }

  codeVerifier(): never {
    throw new McpAuthorizationRequired(
      `the OAuth credential "${this.name}" requires an interactive authorization`,
      this.name,
    );
  }
}

/** Load the named credential, turning absence into the park signal. Split from the provider so the
 *  transport can park a dispatch before constructing any SDK machinery. */
export async function loadStoredCredential(
  name: string,
  store: McpCredentialStore,
): Promise<LoadedMcpOAuthCredential> {
  const record = await store.load(name);
  if (record === null) {
    throw new McpAuthorizationRequired(
      `no OAuth credential named "${name}" is stored for this project; authorization is required`,
      name,
    );
  }
  return record;
}
