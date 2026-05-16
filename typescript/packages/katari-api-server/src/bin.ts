// Process entry. Wires Postgres + console logger + Hono and starts an HTTP
// server on PORT (default 8080). Apply `storage/schema.sql` to your
// database before first launch.

import { serve } from "@hono/node-server";
import {
  buildConsoleLogger,
  loadSubprocessSidecar,
  SidecarManager,
  type LogLevel,
  type Logger,
  type Sidecar,
} from "katari-runtime";
import { buildMetrics } from "./metrics.js";
import { Orchestrator } from "./orchestrator.js";
import { recoverOnBoot } from "./recovery.js";
import { buildApp } from "./routes/app.js";
import { ProjectService } from "./services/project-service.js";
import { SnapshotService } from "./services/snapshot-service.js";
import { PostgresStorage } from "./storage/pg.js";
import type { SnapshotId } from "./storage/types.js";

const databaseUrl = process.env.DATABASE_URL;
if (databaseUrl === undefined || databaseUrl === "") {
  console.error("DATABASE_URL is required");
  process.exit(1);
}
const port = Number(process.env.PORT ?? 8080);

const logLevel = (process.env.LOG_LEVEL ?? "info") as LogLevel;
const logger = buildConsoleLogger(logLevel);

const apiKey = process.env.KATARI_API_KEY;
if (apiKey === undefined || apiKey === "") {
  logger.log(
    "warn",
    "KATARI_API_KEY is not set; the auth middleware will reject every request with 503",
  );
}

const storage = PostgresStorage.create(databaseUrl);
const metrics = buildMetrics();

// Sidecar manager: per snapshot we spawn a `node <bundle.mjs>`
// subprocess. Snapshots without a bundle (= no ext agent declarations)
// short-circuit to `null` so the orchestrator skips FFI plumbing.
const sidecarManager = new SidecarManager<SnapshotId>(
  async (_key, bundle, sidecarLogger: Logger): Promise<Sidecar | null> => {
    if (bundle === null) return null;
    return await loadSubprocessSidecar({ bundle, logger: sidecarLogger });
  },
  logger,
);

const projects = new ProjectService(storage, logger);
const snapshots = new SnapshotService(storage, logger);
const orchestrator = new Orchestrator(storage, sidecarManager, logger);

await recoverOnBoot(storage, orchestrator, logger);

const app = buildApp({
  storage,
  projects,
  snapshots,
  orchestrator,
  apiKey,
  metrics,
});

const server = serve({ fetch: app.fetch, port });
logger.log("info", "katari-api-server listening", { port });

// ─── Graceful shutdown ─────────────────────────────────────────────────────

let shuttingDown = false;
const shutdown = (signal: string): void => {
  if (shuttingDown) return;
  shuttingDown = true;
  logger.log("info", "shutdown initiated", { signal });
  server.close(async (err) => {
    if (err !== undefined && err !== null) {
      logger.log("error", "server.close error", { error: err.message });
    }
    try {
      await sidecarManager.shutdown();
    } catch (sidecarErr) {
      logger.log("error", "sidecarManager.shutdown error", {
        error:
          sidecarErr instanceof Error ? sidecarErr.message : String(sidecarErr),
      });
    }
    try {
      await storage.close?.();
    } catch (closeErr) {
      logger.log("error", "storage.close error", {
        error:
          closeErr instanceof Error ? closeErr.message : String(closeErr),
      });
    }
    logger.log("info", "shutdown complete");
    process.exit(0);
  });
  setTimeout(() => {
    logger.log("error", "shutdown timed out, forcing exit");
    process.exit(1);
  }, 30_000).unref();
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

process.on("unhandledRejection", (reason) => {
  logger.log("error", "unhandledRejection", {
    reason: reason instanceof Error ? reason.message : String(reason),
    stack: reason instanceof Error ? reason.stack : undefined,
  });
});

process.on("uncaughtException", (err) => {
  logger.log("error", "uncaughtException", {
    error: err.message,
    stack: err.stack,
  });
  process.exit(1);
});

void metrics; // metrics surface kept for routes/app.ts probes
