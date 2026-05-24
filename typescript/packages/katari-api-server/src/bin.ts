// Process entry. Wires Postgres + console logger + Hono and starts an HTTP
// server on PORT (default 8000). The bundled `schema.sql` is applied
// automatically on boot (idempotent — safe to re-run). Set
// `KATARI_AUTO_MIGRATE=false` to opt out if you migrate via your own
// tooling.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { serve } from "@hono/node-server";
import {
  buildConsoleLogger,
  loadSubprocessSidecar,
  SidecarManager,
  type LogLevel,
  type Logger,
  type Sidecar,
} from "@katari-lang/runtime";
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
const port = Number(process.env.PORT ?? 8000);

const logLevel = (process.env.LOG_LEVEL ?? "info") as LogLevel;
const logger = buildConsoleLogger(logLevel);

const apiKey = process.env.KATARI_API_KEY;
if (apiKey === undefined || apiKey === "") {
  // Refuse to boot — an unset API key in production would make every
  // call return 503 anyway, and a misconfigured deployment that silently
  // accepts traffic on a non-functional auth path is strictly worse than
  // failing loud at startup. Set KATARI_API_KEY=disabled to opt out of
  // auth entirely (only safe for local dev / sandboxes).
  console.error(
    "KATARI_API_KEY is required (set to 'disabled' to allow unauthenticated access in dev)",
  );
  process.exit(1);
}
const authDisabled = apiKey === "disabled";
if (authDisabled) {
  logger.log(
    "warn",
    "KATARI_API_KEY=disabled — auth middleware is OFF; do not run this configuration in production",
  );
}

const storage = PostgresStorage.create(databaseUrl);
const metrics = buildMetrics();

if (process.env.KATARI_AUTO_MIGRATE !== "false") {
  // dist/bin.js → ../src/storage/schema.sql. The path resolves the
  // same way under `pnpm deploy` (Docker), bare `node dist/bin.js`,
  // and an npm-installed @katari-lang/api-server.
  const schemaPath = resolve(
    dirname(fileURLToPath(import.meta.url)),
    "..",
    "src",
    "storage",
    "schema.sql",
  );
  const schemaSql = readFileSync(schemaPath, "utf8");
  await storage.migrate(schemaSql);
  logger.log("info", "schema migration applied", { schemaPath });
}

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

// Admin web SPA: serve from $KATARI_ADMIN_WEB_DIST if set (= the built
// `dist/` directory). When unset, the runtime works fine without a UI.
const adminWebDistPath =
  process.env.KATARI_ADMIN_WEB_DIST !== undefined &&
  process.env.KATARI_ADMIN_WEB_DIST !== ""
    ? process.env.KATARI_ADMIN_WEB_DIST
    : null;

const app = buildApp({
  storage,
  projects,
  snapshots,
  orchestrator,
  logger,
  apiKey: authDisabled ? null : apiKey,
  metrics,
  adminWebDistPath,
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
