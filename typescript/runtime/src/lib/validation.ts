import { zValidator as baseZValidator } from "@hono/zod-validator";
import type { ValidationTargets } from "hono";
import type { ZodType } from "zod";

/**
 * `zValidator` with a hook that throws the `ZodError` on failure instead of returning the library's
 * default bare `400`. That routes validation failures through the central error handler, so every
 * failure — validation or domain — comes back in the same `{ ok: false, error }` envelope (the
 * handler maps a `ZodError` to a 422). Import this everywhere instead of the raw library export.
 */
export const zValidator = <Target extends keyof ValidationTargets, Schema extends ZodType>(
  target: Target,
  schema: Schema,
) =>
  baseZValidator(target, schema, (result) => {
    if (!result.success) {
      throw result.error;
    }
  });
