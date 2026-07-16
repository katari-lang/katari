// The `oauth_clients` registry as the admin API and the runtime present it. The service owns the AES-GCM
// envelope over the client secret (sealed here, never in the repository), so the secret is write-only over
// the API — an operator registers it, the runtime reads it for the token exchange (the configured
// acquisition flow) and the refresh (the credentials core), but it never reads back in plaintext.

import { db } from "../../db/client.js";
import { decryptSecret, encryptSecret } from "../../lib/crypto.js";
import { NotFoundError } from "../../lib/errors.js";
import type { ConfiguredClientCredentials } from "../../runtime/external/credentials.js";
import { type OauthClientMetadata, oauthClientRepository } from "./oauth-client.repository.js";

/** What a PUT registers. Every plain field is a full replace; the SECRET is the exception, because it is
 *  write-only and so cannot round-trip through a re-register form: an ABSENT `clientSecret` means "keep
 *  whatever is stored" (on a fresh registration there is nothing to keep — a public client), and the
 *  explicit `clearSecret` flag is the deliberate downgrade to a public client. Without this split, editing
 *  a confidential client with the secret field blank would silently erase the secret and kill its
 *  refreshes. */
export interface OauthClientInput {
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  /** A NEW client secret to store (sealed), or absent to keep the currently stored one. Write-only. */
  clientSecret?: string;
  /** The explicit "remove the secret — make this a public client" switch. Mutually exclusive with a new
   *  `clientSecret` (the route rejects both together). */
  clearSecret: boolean;
  scopes: string[];
  /** Extra authorize-URL query parameters (e.g. Google's `access_type=offline`, `prompt=consent`) —
   *  provider configuration, not a secret: it rides both directions of the wire. */
  authorizationParameters: Record<string, string>;
}

/** The registered client's configuration the acquisition flow needs (secret unsealed for the code
 *  exchange). `null` when no client is registered under the name. */
export interface OauthClientConfig {
  name: string;
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  /** The unsealed client secret, or `null` for a public client. */
  clientSecret: string | null;
  scopes: string[];
  authorizationParameters: Record<string, string>;
}

export const oauthClientService = {
  /** Register (or replace) a client — a full replace of the plain fields, with the secret following its
   *  three-way action (see `OauthClientInput`): a new value seals and stores, `clearSecret` erases (the
   *  explicit public downgrade), and absence keeps the stored secret across the re-register. */
  async upsert(projectId: string, name: string, input: OauthClientInput): Promise<void> {
    await oauthClientRepository.upsert(db, projectId, {
      name,
      issuer: input.issuer,
      authorizeEndpoint: input.authorizeEndpoint,
      tokenEndpoint: input.tokenEndpoint,
      clientId: input.clientId,
      secret: input.clearSecret
        ? { kind: "clear" }
        : input.clientSecret === undefined
          ? { kind: "keep" }
          : { kind: "set", sealed: encryptSecret(input.clientSecret) },
      scopes: input.scopes,
      authorizationParameters: input.authorizationParameters,
    });
  },

  /** The registered clients as metadata (the secret is never returned — write-only). The wire shape nests
   *  under `clients` so the resource can grow siblings without a breaking change. */
  async list(projectId: string): Promise<{ clients: OauthClientMetadata[] }> {
    return { clients: await oauthClientRepository.list(db, projectId) };
  },

  /** Delete a registered client. 404 when nothing is registered under the name. */
  async delete(projectId: string, name: string): Promise<void> {
    const deleted = await oauthClientRepository.delete(db, projectId, name);
    if (!deleted) {
      throw new NotFoundError(`no OAuth client named "${name}" is registered for this project`);
    }
  },

  /** The registered client's full configuration (secret unsealed) for the acquisition flow's code
   *  exchange. `null` when no client is registered — the caller turns that into a 400 "no client
   *  registered". */
  async loadConfig(projectId: string, name: string): Promise<OauthClientConfig | null> {
    const row = await oauthClientRepository.load(db, projectId, name);
    if (row === null) return null;
    return {
      name: row.name,
      issuer: row.issuer,
      authorizeEndpoint: row.authorizeEndpoint,
      tokenEndpoint: row.tokenEndpoint,
      clientId: row.clientId,
      clientSecret: unsealSecret(row.sealedSecret),
      scopes: row.scopes,
      authorizationParameters: row.authorizationParameters,
    };
  },

  /** The registered client's authentication material for the credentials core's refresh — the `client_id`
   *  and the unsealed `client_secret` (`null` for a public client). `null` when the operator deleted the
   *  client (the refresh is then dead — the resolution parks for re-login). */
  async resolveClientCredentials(
    projectId: string,
    name: string,
  ): Promise<ConfiguredClientCredentials | null> {
    const row = await oauthClientRepository.load(db, projectId, name);
    if (row === null) return null;
    return { clientId: row.clientId, clientSecret: unsealSecret(row.sealedSecret) };
  },
};

/** Unseal a stored client secret. An unsealable value (key rotation, storage corruption) reads as `null`
 *  — a public client — rather than surfacing as a distinct error: a client that cannot be authenticated
 *  as confidential is re-registered, the same remedy as a genuinely public one that will not authorize. */
function unsealSecret(sealed: string | null): string | null {
  if (sealed === null) return null;
  try {
    return decryptSecret(sealed);
  } catch {
    return null;
  }
}
