import { createMiddleware } from "hono/factory";
import { UnsupportedMediaTypeError } from "../lib/errors.js";
import type { AppEnv } from "../types/app-env.js";

/**
 * Guards routes that take a JSON body. Hono only parses the body when the `Content-Type` is
 * `application/json`; under any other type it hands the validator an empty `{}`, so a payload sent
 * with the wrong type is silently dropped — and passes validation outright when every field is
 * optional (e.g. a cancel `reason`). Reject such a request loudly with 415 instead.
 *
 * A missing `Content-Type` is allowed on purpose: a legitimately body-less request (cancel with no
 * reason) sends no type, and forcing one would break it.
 */
export const requireJsonBody = createMiddleware<AppEnv>(async (c, next) => {
  const contentType = c.req.header("content-type");
  if (contentType && !contentType.toLowerCase().includes("application/json")) {
    throw new UnsupportedMediaTypeError(
      `This endpoint expects Content-Type application/json, but received "${contentType}".`,
    );
  }
  await next();
});
