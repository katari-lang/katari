import { serve } from "@hono/node-server";
import { Runtime } from "./runtime/index.js";
import { buildApp, resolveMetadata } from "./server.js";
import { Db, createPostgresAdapter } from "./db.js";
import { decodeModule } from "./ir.js";
import type { JsonValue } from "katari-protocol";
import { ConsoleRuntimeLogger } from "./logger.js";

const PORT = parseInt(process.env["PORT"] ?? "8000", 10);
const KATARI_BASE_URL = process.env["KATARI_BASE_URL"] ?? `http://localhost:${PORT}/katari`;
const DATABASE_URL =
  process.env["DATABASE_URL"] ??
  "postgresql://katari:katari@localhost:5432/katari";

async function main() {
  const logger = new ConsoleRuntimeLogger({ prefix: "runtime" });

  const adapter = await createPostgresAdapter(DATABASE_URL);
  const db = new Db(adapter);
  await db.initialize();

  // Mark stale "running" agents from previous session as "stopped"
  const cleaned = await db.cleanupStaleAgents();
  if (cleaned > 0) {
    logger.log("info", `Cleaned up ${cleaned} stale agent(s) from previous session`);
  }

  const runtime = new Runtime(KATARI_BASE_URL, db, logger);

  // Wire toplevel agent lifecycle callbacks
  runtime.onAgentCompleted = async (agentId, result) => {
    await db.updateAgentStatus(agentId, "completed", result as JsonValue);
  };
  runtime.onAgentError = async (agentId) => {
    await db.updateAgentStatus(agentId, "error", null);
  };

  // Restore latest module from DB
  const saved = await db.loadLatestModule();
  if (saved) {
    try {
      const module = decodeModule(saved.ktriBinary);
      const aliasEndpoints = new Map(Object.entries(saved.aliasEndpoints));
      const schemas = new Map(
        Object.entries(saved.schemas)
      ) as Map<string, JsonValue>;
      const { nameMap, externalAgents } = resolveMetadata(saved.agents, aliasEndpoints);
      runtime.applyModule(module, nameMap, schemas, externalAgents, aliasEndpoints);
      logger.log("info", `Restored module: ${module.name}`);

      // Restore running agents from DB
      await runtime.restoreAgentsFromDb();
    } catch (e) {
      logger.log("warn", `Failed to restore module: ${e}`);
    }
  }

  const app = buildApp(runtime, db, logger);

  logger.log("info", `Katari Runtime listening on http://localhost:${PORT}`);
  serve({ fetch: app.fetch, port: PORT });
}

main().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
