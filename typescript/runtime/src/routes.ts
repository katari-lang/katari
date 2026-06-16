import { Hono } from "hono";
import type { AppEnv } from "./types/app-env.js";

/**
 * Versioned API surface. Mount feature modules here; each owns its own sub-path and stays
 * self-contained under `src/modules/<name>`. Empty until the v0.1.0 resource modules land
 * (project / snapshot / run / escalation / file / env / agent).
 */
export const apiRoutes = new Hono<AppEnv>();
