import { serve } from "@hono/node-server";
import { Runtime } from "./runtime/index.js";
import { buildApp } from "./server.js";
import { Db } from "./db.js";
import { decodeModule } from "./ir.js";

const PORT = parseInt(process.env["PORT"] ?? "8000", 10);
const BASE_URL = process.env["BASE_URL"] ?? `http://localhost:${PORT}/katari`;
const DB_PATH = process.env["DB_PATH"] ?? "katari.db";

const db = new Db(DB_PATH);
const runtime = new Runtime(BASE_URL);

// Restore latest module from DB
const saved = db.loadLatestModule();
if (saved) {
  try {
    const module = decodeModule(saved.ktriBinary);
    const nameMap = new Map(Object.entries(saved.agentNameMap));
    const schemas = new Map(Object.entries(saved.schemas)) as Map<string, import("katari-protocol").JsonValue>;
    const servers = new Map(Object.entries(saved.servers));
    const externalAgents = new Map(
      Object.entries(saved.externalAgents).map(([k, v]) => [parseInt(k, 10), v])
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
