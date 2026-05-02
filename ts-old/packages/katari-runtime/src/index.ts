import { serve } from "@hono/node-server";
import { Runtime } from "./runtime/index.js";
import { buildApp, resolveExternalAgents, buildNameToAgentRef } from "./server.js";
import { Db, createPostgresAdapter } from "./db.js";
import { decodeModule } from "./ir.js";
import { PostgresKatariStore, type JsonValue } from "katari-protocol";
import { ConsoleRuntimeLogger } from "./logger.js";

const PORT = parseInt(process.env["PORT"] ?? "8000", 10);
const KATARI_BASE_URL =
  process.env["KATARI_BASE_URL"] ?? `http://localhost:${PORT}/katari`;
const DATABASE_URL =
  process.env["DATABASE_URL"] ??
  "postgresql://katari:katari@localhost:5432/katari";

async function main() {
  const logger = new ConsoleRuntimeLogger({ prefix: "runtime" });

  const adapter = await createPostgresAdapter(DATABASE_URL);
  const db = new Db(adapter);
  await db.initialize();

  const protocolStore = new PostgresKatariStore(adapter);
  await protocolStore.initialize();

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
      const schemas = new Map(Object.entries(saved.schemas)) as Map<
        string,
        JsonValue
      >;
      // Use resolved external agents (with UUIDs) from DB if available, else fall back to name-based
      const externalAgents = Object.keys(saved.resolvedExternalAgents).length > 0
        ? new Map(Object.entries(saved.resolvedExternalAgents).map(([k, v]) => [Number(k), v]))
        : resolveExternalAgents(saved.agents, aliasEndpoints);
      const protocolDefIdToBlockId = new Map(
        Object.entries(saved.protocolDefMap).map(([k, v]) => [k, v]),
      );
      const primBlockIds = new Map<number, string>();
      for (const entry of saved.agents) {
        if (entry.kind === "prim") {
          primBlockIds.set(entry.block_id, entry.name);
        }
      }
      const nameToAgentRef = buildNameToAgentRef(
        saved.agents,
        externalAgents,
        protocolDefIdToBlockId,
        schemas,
        KATARI_BASE_URL,
      );
      runtime.applyModule(
        module,
        protocolDefIdToBlockId,
        externalAgents,
        aliasEndpoints,
        primBlockIds,
        nameToAgentRef,
      );
      const templateMap = new Map<string, number>();
      const templateEndpoints = new Map<string, string>();
      for (const [templateId, info] of Object.entries(saved.protocolTemplateMap)) {
        templateMap.set(templateId, info.request_id);
        templateEndpoints.set(templateId, info.endpoint);
      }
      runtime.setProtocolTemplateMap(templateMap, templateEndpoints);
      logger.log("info", `Restored module: ${module.name}`);

      // Restore running agents from DB
      await runtime.restoreAgentsFromDb();
    } catch (e) {
      logger.log("warn", `Failed to restore module: ${e}`);
    }
  }

  const app = buildApp(runtime, db, protocolStore, logger);

  logger.log("info", `Katari Runtime listening on http://localhost:${PORT}`);
  serve({ fetch: app.fetch, port: PORT });
}

main().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
