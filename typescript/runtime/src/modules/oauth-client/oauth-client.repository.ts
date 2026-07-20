// Persistence for the `oauth_clients` registry (docs/2026-07-14-credentials-core.md Phase 2 §3): the
// operator-registered OAuth clients a `configured` credential authenticates as. The repository speaks in
// SEALED secrets (the AES-GCM envelope over `client_secret`); sealing / unsealing stays with the service,
// so this layer is a pure row store. A `null` sealed secret is a genuine absence — a public client.

import { and, eq } from "drizzle-orm";
import type { Executor } from "../../db/client.js";
import { oauthClients } from "../../db/tables/oauth-clients.js";

/** One registered client's stored row, secret still sealed (`null` for a public client). */
export interface OauthClientRow {
  name: string;
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  /** The AES-GCM sealed secret, or `null` for a public client. */
  sealedSecret: string | null;
  scopes: string[];
  /** Extra authorize-URL query parameters (see the table column) — plain data, never sealed. */
  authorizationParameters: Record<string, string>;
}

/** What an upsert does to the stored client secret — a three-way sum, because the secret is WRITE-ONLY:
 *  a re-register form cannot round-trip the current secret, so "no secret in the request" must not mean
 *  "erase it" (that would silently downgrade a confidential client to public and kill its refreshes).
 *  `set` stores a newly sealed secret, `clear` is the EXPLICIT downgrade to a public client, and `keep`
 *  leaves whatever is stored untouched (a fresh insert under `keep` stores none — a new public client). */
export type SealedSecretAction =
  | { kind: "set"; sealed: string }
  | { kind: "clear" }
  | { kind: "keep" };

/** The metadata face of a registered client — everything BUT the secret material (write-only over the
 *  API): `hasSecret` says whether a secret is stored, without revealing it. The authorization parameters
 *  ARE here: they are provider configuration, not a secret. */
export interface OauthClientMetadata {
  name: string;
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  hasSecret: boolean;
  scopes: string[];
  authorizationParameters: Record<string, string>;
}

/** What an upsert writes: every plain field (a full replace), plus the secret ACTION — the one field a
 *  PUT cannot replace verbatim, because it is write-only and so absent from a round-tripped form. */
export interface OauthClientWrite {
  name: string;
  issuer: string;
  authorizeEndpoint: string;
  tokenEndpoint: string;
  clientId: string;
  secret: SealedSecretAction;
  scopes: string[];
  authorizationParameters: Record<string, string>;
}

export const oauthClientRepository = {
  /** Register (or replace) one client. Every plain field is a full replace (PUT semantics); the secret
   *  follows its ACTION — `set` / `clear` write, `keep` leaves an existing row's secret column out of the
   *  conflict-update entirely so the stored value survives the replace. */
  async upsert(executor: Executor, projectId: string, client: OauthClientWrite): Promise<void> {
    const replaced = {
      issuer: client.issuer,
      authorizeEndpoint: client.authorizeEndpoint,
      tokenEndpoint: client.tokenEndpoint,
      clientId: client.clientId,
      scopes: client.scopes,
      authorizationParameters: client.authorizationParameters,
    };
    await executor
      .insert(oauthClients)
      .values({
        projectId,
        name: client.name,
        ...replaced,
        // A fresh insert under `keep` has nothing to keep — it registers a public client (no secret).
        clientSecret: client.secret.kind === "set" ? client.secret.sealed : null,
      })
      .onConflictDoUpdate({
        target: [oauthClients.projectId, oauthClients.name],
        set: {
          ...replaced,
          // `keep` omits the column from the set-clause, so the existing sealed secret stands.
          ...(client.secret.kind === "keep"
            ? {}
            : { clientSecret: client.secret.kind === "set" ? client.secret.sealed : null }),
        },
      });
  },

  /** The registered clients as metadata (secret withheld — write-only), in stable name order. */
  async list(executor: Executor, projectId: string): Promise<OauthClientMetadata[]> {
    const rows = await executor
      .select({
        name: oauthClients.name,
        issuer: oauthClients.issuer,
        authorizeEndpoint: oauthClients.authorizeEndpoint,
        tokenEndpoint: oauthClients.tokenEndpoint,
        clientId: oauthClients.clientId,
        clientSecret: oauthClients.clientSecret,
        scopes: oauthClients.scopes,
        authorizationParameters: oauthClients.authorizationParameters,
      })
      .from(oauthClients)
      .where(eq(oauthClients.projectId, projectId))
      .orderBy(oauthClients.name);
    return rows.map(({ clientSecret, ...rest }) => ({ ...rest, hasSecret: clientSecret !== null }));
  },

  /** One client's full stored row (secret still sealed) — the runtime's own read for the token exchange /
   *  refresh. `null` when no client is registered under the name. */
  async load(executor: Executor, projectId: string, name: string): Promise<OauthClientRow | null> {
    const [row] = await executor
      .select({
        name: oauthClients.name,
        issuer: oauthClients.issuer,
        authorizeEndpoint: oauthClients.authorizeEndpoint,
        tokenEndpoint: oauthClients.tokenEndpoint,
        clientId: oauthClients.clientId,
        sealedSecret: oauthClients.clientSecret,
        scopes: oauthClients.scopes,
        authorizationParameters: oauthClients.authorizationParameters,
      })
      .from(oauthClients)
      .where(and(eq(oauthClients.projectId, projectId), eq(oauthClients.name, name)))
      .limit(1);
    return row ?? null;
  },

  /** Delete a registered client. Returns whether a row existed. */
  async delete(executor: Executor, projectId: string, name: string): Promise<boolean> {
    const deleted = await executor
      .delete(oauthClients)
      .where(and(eq(oauthClients.projectId, projectId), eq(oauthClients.name, name)))
      .returning({ name: oauthClients.name });
    return deleted.length > 0;
  },
};
