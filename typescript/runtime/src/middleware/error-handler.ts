import type { ErrorHandler } from "hono";
import { HTTPException } from "hono/http-exception";
import { ZodError } from "zod";
import { AppError } from "../lib/errors.js";
import type { ErrorBody } from "../lib/response.js";
import type { AppEnv } from "../types/app-env.js";

/**
 * Central error boundary. Maps known error shapes to the standard error
 * envelope; everything unexpected is logged and returned as a 500.
 */
export const errorHandler: ErrorHandler<AppEnv> = (err, c) => {
  const logger = c.get("logger");

  if (err instanceof AppError) {
    logger?.warn("request failed", {
      code: err.code,
      status: err.status,
      message: err.message,
    });
    const body: ErrorBody = {
      ok: false,
      error: { code: err.code, message: err.message, details: err.details },
    };
    return c.json(body, err.status);
  }

  if (err instanceof ZodError) {
    const body: ErrorBody = {
      ok: false,
      error: {
        code: "validation_error",
        message: "Validation failed",
        details: err.issues,
      },
    };
    return c.json(body, 422);
  }

  if (err instanceof HTTPException) {
    const body: ErrorBody = {
      ok: false,
      error: { code: "http_exception", message: err.message },
    };
    return c.json(body, err.status);
  }

  logger?.error("unhandled error", {
    message: err instanceof Error ? err.message : String(err),
    stack: err instanceof Error ? err.stack : undefined,
  });
  const body: ErrorBody = {
    ok: false,
    error: { code: "internal_server_error", message: "Internal Server Error" },
  };
  return c.json(body, 500);
};
