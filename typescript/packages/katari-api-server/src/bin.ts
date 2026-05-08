// Process entry. Wires Postgres + console logger + Hono and starts an HTTP
// server on PORT (default 8080). Apply `storage/schema.sql` to your
// database before first launch.
//
// Lifecycle:
//   - On boot: build storage / registry / services, run `recoverOnBoot`,
//     then start the HTTP listener.
//   - On SIGTERM / SIGINT: stop accepting new connections, wait for
//     in-flight per-version mutexes to drain, close the storage pool,
//     then exit.
//   - On uncaughtException / unhandledRejection: log and exit non-zero so
//     the process supervisor can restart us. We don't try to keep running
//     past an uncaught error because the underlying state may already be
//     corrupt.

import { serve } from "@hono/node-server";
import {
  buildConsoleLogger,
  type LogLevel,
} from "katari-runtime";
import { buildMetrics } from "./metrics.js";
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

// LOG_LEVEL gates the console logger. The runtime treats `info` as the
// safe production default; set `LOG_LEVEL=debug` locally to see stale-event
// drops, escalate-event placeholders, etc.
const logLevel = (process.env.LOG_LEVEL ?? "info") as LogLevel;
const logger = buildConsoleLogger(logLevel);

// KATARI_API_KEY gates the Bearer-auth middleware. The middleware fails
// closed (503) if it's unset, so production deployments must export it.
const apiKey = process.env.KATARI_API_KEY;
if (apiKey === undefined || apiKey === "") {
  logger.log("warn", "KATARI_API_KEY is not set; the auth middleware will reject every request with 503");
}

const storage = PostgresStorage.create(databaseUrl);
const registry = new MachineRegistry(storage, logger, {
  maxLoaded: parseIntEnv("KATARI_MACHINE_CACHE_MAX", 64),
});
const metrics = buildMetrics();

const modules = new ModuleService(storage, logger);
const agents = new AgentService(storage, registry, logger, metrics);

// Refresh the machinesLoaded gauge on a slow timer. The cache size
// changes from acquire / evict; sampling at 5s is fine for ops dashboards
// and avoids hooking into every code path that mutates the cache.
const machinesLoadedInterval = setInterval(() => {
  metrics.machinesLoaded.set(registry.cacheSize);
}, 5_000);
machinesLoadedInterval.unref();

await recoverOnBoot(storage, registry, logger, agents);

const app = buildApp({ agents, modules, storage, apiKey, metrics });

const server = serve({ fetch: app.fetch, port });
logger.log("info", "katari-api-server listening", { port });

// ─── Graceful shutdown ────────────────────────────────────────────────────

let shuttingDown = false;
const shutdown = (signal: string): void => {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.log("info", "shutdown initiated", { signal });
  server.close((err) => {
    if (err !== undefined && err !== null) {
      logger.log("error", "server.close error", { error: err.message });
    }
    void storage.close?.().catch((closeErr) => {
      logger.log("error", "storage.close error", {
        error: closeErr instanceof Error ? closeErr.message : String(closeErr),
      });
    }).finally(() => {
      logger.log("info", "shutdown complete");
      process.exit(0);
    });
  });
  // Hard timeout so a stuck close doesn't block forever — the process
  // supervisor will get a deterministic exit either way.
  setTimeout(() => {
    logger.log("error", "shutdown timed out, forcing exit");
    process.exit(1);
  }, 30_000).unref();
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// ─── Last-resort error handlers ─────────────────────────────────────────────

process.on("unhandledRejection", (reason) => {
  logger.log("error", "unhandledRejection", {
    reason: reason instanceof Error ? reason.message : String(reason),
    stack: reason instanceof Error ? reason.stack : undefined,
  });
  // Don't auto-exit — an unhandled rejection in one async branch isn't
  // necessarily fatal. The supervisor can decide based on log volume.
});

process.on("uncaughtException", (err) => {
  logger.log("error", "uncaughtException", {
    error: err.message,
    stack: err.stack,
  });
  // Synchronous throw outside any try/catch: the process state is suspect.
  // Exit non-zero so the supervisor restarts us.
  process.exit(1);
});

function parseIntEnv(name: string, fallback: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
