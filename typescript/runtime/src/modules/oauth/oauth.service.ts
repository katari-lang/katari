// Binds the runtime-hosted OAuth authorization flow (runtime/external/authorization-flow.ts) to the host:
// escalations are read from the Layer 1 repository, a `configured`-profile flow reads its client from the
// `oauth_clients` registry, the completed `StoredCredential` is sealed with the same AES-GCM envelope as
// env secrets and deposited through the repository's unconditional upsert ("a new authorization always
// wins"), and each waiting escalation is answered through the facade's ordinary answer path — the flow gets
// no special engine entry.

import { config } from "../../config/index.js";
import { db } from "../../db/client.js";
import { encryptSecret } from "../../lib/crypto.js";
import { createLogger } from "../../lib/logger.js";
import { createAuthorizationFlow } from "../../runtime/external/authorization-flow.js";
import { facade } from "../../runtime/facade.js";
import { credentialRepository } from "../credential/credential.repository.js";
import { escalationRepository } from "../escalation/escalation.repository.js";
import { oauthClientService } from "../oauth-client/oauth-client.service.js";

const logger = createLogger({
  level: config.logLevel,
  bindings: { module: "authorization-flow" },
});

export const authorizationFlow = createAuthorizationFlow({
  publicUrl: config.publicUrl,
  loadOpenEscalation: (projectId, escalationId) =>
    escalationRepository.findOpen(db, projectId, escalationId),
  listOpenEscalations: (projectId) => escalationRepository.listOpen(db, projectId),
  // A configured flow reads its registered client (endpoints, client id, unsealed secret, scopes, extra
  // authorize parameters) from the registry; `null` maps to a 400 "no client registered" inside the flow.
  loadClientConfig: async (projectId, name) => {
    const client = await oauthClientService.loadConfig(projectId, name);
    return client === null
      ? null
      : {
          authorizeEndpoint: client.authorizeEndpoint,
          tokenEndpoint: client.tokenEndpoint,
          clientId: client.clientId,
          clientSecret: client.clientSecret,
          scopes: client.scopes,
          authorizationParameters: client.authorizationParameters,
        };
  },
  // The deposit writes the sealed value AND mirrors its profile tag onto the plaintext discriminant
  // column, so the admin list can dispatch mcp-vs-configured without unsealing anything.
  depositCredential: (projectId, name, credential) =>
    credentialRepository.upsert(
      db,
      projectId,
      name,
      encryptSecret(JSON.stringify(credential)),
      credential.profile,
    ),
  answerEscalation: (projectId, escalationId) =>
    facade.answerEscalation({ projectId, escalationId, value: null }),
  warn: (message, context) => logger.warn(message, context),
  now: () => Date.now(),
});
