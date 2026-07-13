// Binds the runtime-hosted OAuth authorization flow (runtime/external/mcp-authorization-flow.ts) to the
// host: escalations are read from the Layer 1 repository, the completed credential triple is sealed with
// the same AES-GCM envelope as env secrets and deposited through the repository's unconditional upsert
// ("a new authorization always wins"), and each waiting escalation is answered through the facade's
// ordinary answer path — the flow gets no special engine entry.

import { config } from "../../config/index.js";
import { db } from "../../db/client.js";
import { encryptSecret } from "../../lib/crypto.js";
import { createLogger } from "../../lib/logger.js";
import { createMcpAuthorizationFlow } from "../../runtime/external/mcp-authorization-flow.js";
import { facade } from "../../runtime/facade.js";
import { escalationRepository } from "../escalation/escalation.repository.js";
import { mcpCredentialRepository } from "../mcp-credential/mcp-credential.repository.js";

const logger = createLogger({
  level: config.logLevel,
  bindings: { module: "mcp-authorization-flow" },
});

export const mcpAuthorizationFlow = createMcpAuthorizationFlow({
  publicUrl: config.publicUrl,
  loadOpenEscalation: (projectId, escalationId) =>
    escalationRepository.findOpen(db, projectId, escalationId),
  listOpenEscalations: (projectId) => escalationRepository.listOpen(db, projectId),
  depositCredential: (projectId, name, credential) =>
    mcpCredentialRepository.upsert(db, projectId, name, encryptSecret(JSON.stringify(credential))),
  answerEscalation: (projectId, escalationId) =>
    facade.answerEscalation({ projectId, escalationId, value: null }),
  warn: (message, context) => logger.warn(message, context),
  now: () => Date.now(),
});
