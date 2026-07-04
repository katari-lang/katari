#!/usr/bin/env node
import { serve } from "@hono/node-server";
import { config } from "./config/index.js";
import { closeDb } from "./db/client.js";
import { runMigrations } from "./db/migrate.js";
import { app } from "./index.js";
import { createLogger } from "./lib/logger.js";
import { blobStore } from "./runtime/facade.js";
import { ensureBlobStoreReady } from "./runtime/value/blob-store.js";

const logger = createLogger({ level: config.logLevel, bindings: { module: "server" } });

// Apply migrations and provision the blob store before serving. If either fails, do not start (fail fast):
// a missing bucket or unreachable S3 endpoint is a boot-time misconfiguration, not a per-upload surprise.
try {
  await runMigrations();
  await ensureBlobStoreReady(blobStore);
} catch (err) {
  logger.error("startup failed; not starting server", {
    message: err instanceof Error ? err.message : String(err),
  });
  process.exit(1);
}

const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
  logger.info("katari-api-server started", {
    url: `http://${config.host}:${info.port}`,
    env: config.nodeEnv,
  });
});

const shutdown = (signal: NodeJS.Signals): void => {
  logger.info("shutting down", { signal });
  server.close(async (err) => {
    await closeDb().catch(() => {});
    if (err) {
      logger.error("error during shutdown", { message: err.message });
      process.exit(1);
    }
    process.exit(0);
  });
};

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => shutdown(signal));
}
