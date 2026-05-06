// Process entry. Wires Postgres + console logger + Hono and starts an HTTP
// server on PORT (default 8080). Apply `storage/schema.sql` to your
// database before first launch.

import { serve } from "@hono/node-server";
import { consoleLogger } from "katari-runtime";
import { MachineRegistry } from "./registry.js";
import { recoverOnBoot } from "./recovery.js";
import { buildApp } from "./routes/app.js";
import { AgentService } from "./services/agent-service.js";
import { ModuleService } from "./services/module-service.js";
import { PostgresStorage } from "./storage/pg.js";

const databaseUrl = process.env.DATABASE_URL;
if (databaseUrl === undefined || databaseUrl === "") {
  console.error("DATABASE_URL is required");
  process.exit(1);
}
const port = Number(process.env.PORT ?? 8080);

const logger = consoleLogger;
const storage = PostgresStorage.create(databaseUrl);
const registry = new MachineRegistry(storage, logger);

await recoverOnBoot(storage, registry, logger);

const modules = new ModuleService(storage, logger);
const agents = new AgentService(storage, registry, logger);
const app = buildApp({ agents, modules });

serve({ fetch: app.fetch, port });
logger.log("info", "katari-api-server listening", { port });
