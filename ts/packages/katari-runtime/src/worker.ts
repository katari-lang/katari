/**
 * Cloudflare Workers entry point for Katari Runtime
 *
 * Uses Neon's serverless driver for PostgreSQL over HTTP.
 * Hono handles routing natively in Workers.
 */
import { Runtime } from "./runtime/index.js";
import { buildApp, resolveMetadata } from "./server.js";
import { Db } from "./db.js";
import { createNeonAdapter } from "./neon-adapter.js";
import { decodeModule } from "./ir.js";
import { PostgresKatariStore, type JsonValue } from "katari-protocol";
import { ConsoleRuntimeLogger } from "./logger.js";

export interface Env {
  DATABASE_URL: string;
  KATARI_BASE_URL: string;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const logger = new ConsoleRuntimeLogger({ prefix: "runtime" });
    const adapter = createNeonAdapter(env.DATABASE_URL);
    const db = new Db(adapter);
    await db.initialize();

    const protocolStore = new PostgresKatariStore(adapter);
    await protocolStore.initialize();

    const runtime = new Runtime(env.KATARI_BASE_URL, db, logger);

    // Wire toplevel agent lifecycle callbacks
    runtime.onAgentCompleted = async (agentId, result) => {
      await db.updateAgentStatus(agentId, "completed", result as JsonValue);
    };
    runtime.onAgentError = async (agentId) => {
      await db.updateAgentStatus(agentId, "error", null);
    };

    // Restore module from DB
    const saved = await db.loadLatestModule();
    if (saved) {
      try {
        const module = decodeModule(saved.ktriBinary);
        const aliasEndpoints = new Map(Object.entries(saved.aliasEndpoints));
        const schemas = new Map(Object.entries(saved.schemas)) as Map<
          string,
          JsonValue
        >;
        const { nameMap, externalAgents } = resolveMetadata(
          saved.agents,
          aliasEndpoints,
        );
        runtime.applyModule(
          module,
          nameMap,
          schemas,
          externalAgents,
          aliasEndpoints,
        );
      } catch (e) {
        logger.log("warn", `Failed to restore module: ${e}`);
      }
    }

    const app = buildApp(runtime, db, protocolStore, logger);
    return app.fetch(request);
  },
};
