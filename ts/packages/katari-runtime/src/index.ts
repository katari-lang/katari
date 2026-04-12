import { serve } from "@hono/node-server";
import { Runtime } from "./runtime/index.js";
import { buildApp } from "./server.js";
import { Db } from "./db.js";
import { decodeModule } from "./ir.js";
import type { JsonValue } from "katari-protocol";

const PORT = parseInt(process.env["PORT"] ?? "8000", 10);
const KATARI_BASE_URL = process.env["KATARI_BASE_URL"] ?? `http://localhost:${PORT}/katari`;
const DATABASE_URL =
  process.env["DATABASE_URL"] ??
  "postgresql://katari:katari@localhost:5432/katari";

async function main() {
  const db = new Db(DATABASE_URL);
  await db.initialize();

  const runtime = new Runtime(KATARI_BASE_URL);

  // Wire toplevel agent lifecycle callbacks
  runtime.onAgentCompleted = async (agentId, result) => {
    await db.updateToplevelAgent(agentId, "completed", result as JsonValue);
  };
  runtime.onAgentError = async (agentId) => {
    await db.updateToplevelAgent(agentId, "error", null);
  };

  // Restore latest module from DB
  const saved = await db.loadLatestModule();
  if (saved) {
    try {
      const module = decodeModule(saved.ktriBinary);
      const nameMap = new Map(Object.entries(saved.agentNameMap));
      const schemas = new Map(
        Object.entries(saved.schemas)
      ) as Map<string, JsonValue>;
      const servers = new Map(Object.entries(saved.servers));
      const externalAgents = new Map(
        Object.entries(saved.externalAgents).map(([k, v]) => [
          parseInt(k, 10),
          v,
        ])
      );
      runtime.applyModule(module, nameMap, schemas, servers, externalAgents);
      console.log(`Restored module: ${module.name}`);
    } catch (e) {
      console.warn("Failed to restore module:", e);
    }
  }

  const app = buildApp(runtime, db);

  console.log(`Katari Runtime listening on http://localhost:${PORT}`);
  serve({ fetch: app.fetch, port: PORT });
}

main().catch((e) => {
  console.error("Failed to start:", e);
  process.exit(1);
});
