// HTTP contract for the `oauth_clients` registry: register (PUT), list (GET), forget (DELETE). The client
// secret crosses this surface ONLY inbound (a PUT deposits it, sealed thereafter) — it is never returned.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

/** The `:name` path parameter alongside the project id (the client's registry key). */
export const oauthClientParamSchema = projectIdParamSchema.extend({ name: z.string().min(1) });

/** A PUT's body — a full replace of the plain fields, with three-way secret semantics (the secret is
 *  write-only, so a re-register form cannot echo it back): a present `clientSecret` stores a new one, an
 *  ABSENT one KEEPS whatever is stored (nothing, on a fresh registration — a public client), and
 *  `clearSecret: true` is the explicit downgrade to a public client. Sending both a new secret and the
 *  clear flag is contradictory and rejected. `scopes` and `authorizationParameters` (extra
 *  provider-specific authorize-URL parameters — plain configuration, returned by the GET) default to
 *  empty. */
export const oauthClientBodySchema = z
  .object({
    issuer: z.string().min(1),
    authorizeEndpoint: z.string().url(),
    tokenEndpoint: z.string().url(),
    clientId: z.string().min(1),
    clientSecret: z.string().min(1).optional(),
    clearSecret: z.boolean().default(false),
    scopes: z.array(z.string()).default([]),
    authorizationParameters: z.record(z.string(), z.string()).default({}),
  })
  .refine((body) => !(body.clearSecret && body.clientSecret !== undefined), {
    message: "clientSecret and clearSecret are mutually exclusive",
  });
