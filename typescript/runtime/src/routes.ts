import { Hono } from "hono";
import { healthRoutes } from "./modules/health/health.routes.js";
import type { AppEnv } from "./types/app-env.js";

/**
 * Versioned API surface. Mount new feature modules here; each one owns its
 * own sub-path and stays self-contained under `src/modules/<name>`.
 */
export const apiRoutes = new Hono<AppEnv>().route("/health", healthRoutes);
