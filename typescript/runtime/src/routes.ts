import { Hono } from "hono";
import { agentRoutes } from "./modules/agent/agent.routes.js";
import { envRoutes } from "./modules/env/env.routes.js";
import { escalationRoutes } from "./modules/escalation/escalation.routes.js";
import { fileRoutes } from "./modules/file/file.routes.js";
import { healthRoutes } from "./modules/health/health.routes.js";
import { mcpCredentialRoutes } from "./modules/mcp-credential/mcp-credential.routes.js";
import { oauthFlowRoutes } from "./modules/oauth/oauth.routes.js";
import { projectRoutes } from "./modules/project/project.routes.js";
import { runRoutes } from "./modules/run/run.routes.js";
import { snapshotRoutes } from "./modules/snapshot/snapshot.routes.js";
import type { AppEnv } from "./types/app-env.js";

/**
 * Versioned API surface. Each feature module under `src/modules/<name>` owns its own routes and
 * carries the full path (`/projects/...`) internally, so they all mount at the root here and the
 * chained result keeps its types for the RPC client. Health / project / snapshot / run / escalation / file
 * are live; env / agent freeze their contracts and return 501 until those stores land.
 */
export const apiRoutes = new Hono<AppEnv>()
  .route("/", healthRoutes)
  .route("/", projectRoutes)
  .route("/", snapshotRoutes)
  .route("/", runRoutes)
  .route("/", escalationRoutes)
  .route("/", oauthFlowRoutes)
  .route("/", mcpCredentialRoutes)
  .route("/", fileRoutes)
  .route("/", envRoutes)
  .route("/", agentRoutes);
