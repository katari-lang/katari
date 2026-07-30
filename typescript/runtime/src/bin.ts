#!/usr/bin/env node
import { serve } from "@hono/node-server";
import { config } from "./config/index.js";
import { closeDb } from "./db/client.js";
import { acquireInstanceLock, type InstanceLock } from "./db/instance-lock.js";
import { runMigrations } from "./db/migrate.js";
import { app } from "./index.js";
import { createLogger } from "./lib/logger.js";
import { activateInFlightProjects, blobStore } from "./runtime/facade.js";
import { ensureBlobStoreReady } from "./runtime/value/blob-store.js";

const logger = createLogger({ level: config.logLevel, bindings: { module: "server" } });

// Take the single-instance lock, apply migrations, and provision the blob store before serving. If any of
// them fails, do not start (fail fast): a second runtime on the same database, a missing bucket, or an
// unreachable S3 endpoint are all boot-time misconfigurations rather than per-request surprises.
//
// The lock comes FIRST and is held for the process's whole life. It is what keeps two runtimes from both
// reviving the same projects' actors (see `db/instance-lock.ts`), and holding it across `runMigrations`
// also serializes the migrator, which takes no lock of its own.
let instanceLock: InstanceLock | undefined;
try {
  instanceLock = await acquireInstanceLock();
  await runMigrations();
  await ensureBlobStoreReady(blobStore);
} catch (err) {
  logger.error("startup failed; not starting server", {
    error: err instanceof Error ? (err.stack ?? err.message) : String(err),
  });
  await instanceLock?.release().catch(() => {});
  process.exit(1);
}

const server = serve({ fetch: app.fetch, port: config.port, hostname: config.host }, (info) => {
  logger.info("katari-api-server started", {
    url: `http://${config.host}:${info.port}`,
    env: config.nodeEnv,
  });
  // Resume projects with in-flight runs now that the server is listening (a resuming FFI sidecar reaches
  // back over this server's blob side channel). Fire-and-forget: boot must not block on recovery, and each
  // project's failure is already logged inside.
  void activateInFlightProjects(logger).catch((error: unknown) => {
    logger.error("boot-time project resume failed", {
      error: error instanceof Error ? (error.stack ?? error.message) : String(error),
    });
  });
});

const shutdown = (signal: NodeJS.Signals): void => {
  logger.info("shutting down", { signal });
  server.close(async (err) => {
    // Release before closing the pool: the next process's retry loop ends as soon as this lands, which is
    // what keeps a rolling deploy from waiting out the full timeout.
    await instanceLock?.release().catch(() => {});
    await closeDb().catch(() => {});
    if (err) {
      logger.error("error during shutdown", { error: err.message });
      process.exit(1);
    }
    process.exit(0);
  });
};

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => shutdown(signal));
}
