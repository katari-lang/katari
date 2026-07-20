// The `oauth_clients` registry: the operator-registered OAuth clients a `configured`-profile credential
// authenticates as (docs/2026-07-14-credentials-core.md Phase 2 §3). A `configured` credential stores only
// the client's NAME; its `client_id`, its (optional) sealed `client_secret`, the authorization / token
// endpoints and the scopes live here, so a rotated client secret takes effect at the next refresh without
// re-authorizing (the credentials core reads this registry live — `CredentialStore.resolveConfiguredClient`).
//
// `client_secret` is AES-GCM sealed at rest exactly like a credential value (via `lib/crypto`) and is
// write-only over the admin API — an operator registers it, the runtime reads it for the token exchange /
// refresh, but it never reads back in plaintext. A `null` secret is a GENUINE absence: a public client
// (PKCE only, `token_endpoint_auth_method: "none"`), not a missing lookup.

import { jsonb, pgTable, primaryKey, text, uuid } from "drizzle-orm/pg-core";
import { projects } from "./projects.js";

export const oauthClients = pgTable(
  "oauth_clients",
  {
    projectId: uuid("project_id")
      .notNull()
      .references(() => projects.id, { onDelete: "cascade" }),
    /** The client's name — what a `configured` credential (and the `POST /credentials/:name/login` proactive
     *  login, and an `oauth.token(name)` acquisition) references. */
    name: text("name").notNull(),
    /** The OAuth issuer (an identifier for the operator's own reference; the endpoints below are explicit,
     *  so the registry needs no discovery). */
    issuer: text("issuer").notNull(),
    /** The authorization endpoint the acquisition flow redirects the browser to. */
    authorizeEndpoint: text("authorize_endpoint").notNull(),
    /** The token endpoint the code exchange and every later refresh POST to. */
    tokenEndpoint: text("token_endpoint").notNull(),
    /** The registered client id (public — sent in the authorization request). */
    clientId: text("client_id").notNull(),
    /** The AES-GCM sealed client secret, or `null` for a public client (a genuine absence). Write-only
     *  over the API — deposited by an operator, read only by the runtime's own token exchange / refresh. */
    clientSecret: text("client_secret"),
    /** The scopes to request at authorization, as a JSON array of strings. */
    scopes: jsonb("scopes").$type<string[]>().notNull(),
    /** Extra provider-specific query parameters appended verbatim to the authorization URL (string →
     *  string; default empty). Real providers need these — Google issues a refresh token only with
     *  `access_type=offline` + `prompt=consent`, the headline configured-profile use case. This is DATA
     *  on the registry row, not a code branch (the mcp profile is unaffected): the configured flow
     *  appends them after the standard parameters, and a STANDARD parameter wins on a name collision (a
     *  row cannot override `redirect_uri` / `state` / the PKCE pair — see the flow). Not a secret:
     *  readable over the GET, unlike `client_secret`. */
    authorizationParameters: jsonb("authorization_parameters")
      .$type<Record<string, string>>()
      .notNull()
      .default({}),
  },
  (table) => [primaryKey({ columns: [table.projectId, table.name] })],
);
