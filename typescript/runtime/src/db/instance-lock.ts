// The single-instance lock: a Postgres session advisory lock one runtime process holds for its whole life.
//
// Why the runtime needs one. A project's actor is warm, in-memory state — its threads, its in-flight external
// calls, its at-most-once bookkeeping — and `activateInFlightProjects` (see `runtime/facade.ts`) revives an
// actor for EVERY project with a live run on every boot. Two processes against one database therefore both
// host an actor for the same project and both drive the same runs: the at-most-once guarantee that `http` and
// `ffi` recovery depend on is gone, external side effects happen twice, and the two racing writers see each
// other only through READ COMMITTED transactions, which is not enough to serialize a read-then-write on the
// same instance row. Nothing in the engine coordinates across processes — there is no leader election, no
// lease, no `FOR UPDATE SKIP LOCKED`.
//
// This is easy to hit by accident rather than exotic: ECS rolling deploys default to
// `minimumHealthyPercent: 100`, so even at `desiredCount: 1` the old and new tasks overlap on every single
// deploy. Before this lock existed, that overlap silently double-drove every in-flight run.
//
// Holding the lock across migrations solves a second race for free: drizzle's migrator takes no lock of its
// own, so two booting processes would otherwise read the same "last applied" row and both try to apply the
// same DDL.
//
// The lock is advisory and session-scoped, which is the right shape here: Postgres releases it automatically
// if the process dies without cleaning up, so a crashed runtime never leaves the deployment wedged.

import postgres from "postgres";
import { config } from "../config/index.js";
import { createLogger } from "../lib/logger.js";

const logger = createLogger({ level: config.logLevel, bindings: { module: "instance-lock" } });

/** The advisory-lock key. Arbitrary but fixed — any other application using advisory locks in the same
 *  database picks its own, and a collision would only ever cause waiting, never corruption. */
const LOCK_KEY = 0x6b_61_74_61; // "kata"

/** How long to keep trying before giving up, and how long to wait between attempts. The retry loop is what
 *  makes a rolling deploy work: the new process waits for the old one to finish draining and release. */
const RETRY_INTERVAL_MS = 1_000;

/** A held lock, and the way to give it back. */
export interface InstanceLock {
  release(): Promise<void>;
}

/** A lock that owns nothing — what `KATARI_INSTANCE_LOCK=off` hands back. */
const UNHELD: InstanceLock = { release: async () => {} };

function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/**
 * Take the single-instance lock, retrying until `timeoutMs` elapses. Returns the handle on success and
 * throws on timeout — the caller (`bin.ts`) treats that as a refusal to boot, because starting anyway is
 * precisely the situation this exists to prevent.
 *
 * The connection is its own single-connection client rather than one borrowed from the shared pool: a
 * session advisory lock lives on the connection that took it, and a pooled connection would be handed to
 * another query and could be closed underneath us.
 */
export async function acquireInstanceLock(): Promise<InstanceLock> {
  if (!config.instanceLock.enabled) {
    logger.warn(
      "the single-instance lock is disabled (KATARI_INSTANCE_LOCK=off); running two runtimes against one database will double-drive in-flight runs",
    );
    return UNHELD;
  }
  const client = postgres(config.databaseUrl, { max: 1, ssl: config.databaseSslForPostgresJs });
  const deadline = Date.now() + config.instanceLock.timeoutMs;
  let waited = false;
  for (;;) {
    const [row] = await client`SELECT pg_try_advisory_lock(${LOCK_KEY}) AS acquired`;
    if (row?.acquired === true) {
      if (waited) logger.info("the previous runtime released the single-instance lock; continuing");
      return {
        release: async () => {
          // Releasing explicitly keeps a graceful shutdown from making the next process wait out its
          // retry loop; a crash is covered by Postgres dropping the session's locks anyway.
          try {
            await client`SELECT pg_advisory_unlock(${LOCK_KEY})`;
          } finally {
            await client.end();
          }
        },
      };
    }
    if (Date.now() >= deadline) {
      await client.end();
      throw new Error(
        "another runtime already holds the single-instance lock on this database. Only one runtime process " +
          "may serve a database: two would both revive the same projects' actors and double-drive their " +
          "in-flight runs. If this is a rolling deploy, let the previous task finish draining first " +
          "(on ECS, set minimumHealthyPercent to 0) or raise KATARI_INSTANCE_LOCK_TIMEOUT_MS.",
      );
    }
    if (!waited) {
      waited = true;
      logger.info("another runtime holds the single-instance lock; waiting for it to be released");
    }
    await sleep(RETRY_INTERVAL_MS);
  }
}
