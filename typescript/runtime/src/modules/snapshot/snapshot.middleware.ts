import { createMiddleware } from "hono/factory";
import { UnprocessableEntityError } from "../../lib/errors.js";
import type { AppEnv } from "../../types/app-env.js";

// Two hazards in a deploy body can only be caught on the RAW request text, so they are handled here
// rather than in the zod schema, on the single `JSON.parse` this middleware already performs:
//
//   - A reserved object key used as a module NAME. `__proto__` (and, depending on the parser,
//     `constructor` / `prototype`) is special-cased away when JSON is parsed into a JS object — the
//     platform's `Request.json()` strips `__proto__` as prototype-pollution protection. As a module
//     name that means the module is silently dropped from the manifest while the deploy still reports
//     success, leaving an unresolvable reference at run time. The validator re-reads the body from
//     Hono's cache, where the key is already gone, so it cannot see this — only the raw text can.
//
//   - A NUL (U+0000) codepoint in any string. Postgres `jsonb`/`text` cannot store one: an INSERT
//     carrying it aborts the whole deploy transaction with a driver error (a 500). Rejecting it here
//     turns a bad upload into a clean 422 and spares every later stage from re-walking the body for it.
//
// A body that is not valid JSON is passed through so the downstream validator surfaces the proper
// parse error.
const RESERVED_MODULE_NAMES = ["__proto__", "constructor", "prototype"];

// U+0000. Built via `fromCharCode` rather than a string escape so no NUL byte ever enters this source.
const NUL_CHARACTER = String.fromCharCode(0);

const containsNullByte = (value: unknown): boolean => {
  if (typeof value === "string") return value.includes(NUL_CHARACTER);
  if (Array.isArray(value)) return value.some(containsNullByte);
  if (value !== null && typeof value === "object")
    return Object.values(value).some(containsNullByte);
  return false;
};

export const screenRawDeployBody = createMiddleware<AppEnv>(async (c, next) => {
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

  if (containsNullByte(parsed)) {
    throw new UnprocessableEntityError(
      "The deploy body must not contain a NUL character (U+0000).",
    );
  }

  await next();
});
