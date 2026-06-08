import type { Logger } from "../lib/logger.js";

/**
 * The Hono environment for this app. Pass it as `new Hono<AppEnv>()` everywhere
 * so `c.get`/`c.set` and middleware stay fully typed.
 */
export interface AppEnv {
  Variables: {
    requestId: string;
    logger: Logger;
  };
}
