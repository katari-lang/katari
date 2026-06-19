import { createMiddleware } from "hono/factory";
import { UnprocessableEntityError } from "../../lib/errors.js";
import type { AppEnv } from "../../types/app-env.js";

// `__proto__` (and, depending on the parser, `constructor` / `prototype`) gets special-cased away
// when a JSON object is parsed into a JS object — the platform's `Request.json()` strips `__proto__`
// outright as prototype-pollution protection. Used as a module NAME that means the module would be
// silently dropped from the manifest while the deploy still reports success, leaving an unresolvable
// reference at run time. By the time the body is parsed it is already gone, so we cannot detect it
// on the parsed value.
const RESERVED_MODULE_NAMES = ["__proto__", "constructor", "prototype"];

/**
 * Rejects a deploy whose manifest uses a reserved object key as a module name. It inspects the RAW
 * request text with `JSON.parse` — which preserves these keys as own properties — purely to detect
 * and reject them; the downstream validator re-reads the body from Hono's cache as usual. A body
 * that is not valid JSON is passed through so the validator surfaces the proper parse error.
 */
export const rejectReservedModuleNames = createMiddleware<AppEnv>(async (c, next) => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(await c.req.text());
  } catch {
    await next();
    return;
  }

  if (typeof parsed === "object" && parsed !== null && "modules" in parsed) {
    const { modules } = parsed;
    if (typeof modules === "object" && modules !== null) {
      const reserved = RESERVED_MODULE_NAMES.find((name) => Object.hasOwn(modules, name));
      if (reserved) {
        throw new UnprocessableEntityError(
          `A module name must not be a reserved object key ("${reserved}").`,
        );
      }
    }
  }

  await next();
});
