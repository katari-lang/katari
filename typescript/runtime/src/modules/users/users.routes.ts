import { zValidator } from "@hono/zod-validator";
import { Hono } from "hono";
import { success } from "../../lib/response.js";
import type { AppEnv } from "../../types/app-env.js";
import { createUserSchema, listUsersQuerySchema, updateUserSchema } from "./users.schema.js";
import { usersService } from "./users.service.js";

/**
 * HTTP layer for the users resource. Validation is declarative via
 * `zValidator`; handlers stay thin and delegate to the service. Method
 * chaining preserves end-to-end types for the RPC client.
 */
export const usersRoutes = new Hono<AppEnv>()
  .get("/", zValidator("query", listUsersQuerySchema), async (c) => {
    const query = c.req.valid("query");
    const { items, total } = await usersService.list(query);
    return c.json(success({ items, total, limit: query.limit, offset: query.offset }));
  })
  .post("/", zValidator("json", createUserSchema), async (c) => {
    const input = c.req.valid("json");
    const user = await usersService.create(input);
    return c.json(success(user), 201);
  })
  .get("/:id", async (c) => {
    const user = await usersService.get(c.req.param("id"));
    return c.json(success(user));
  })
  .patch("/:id", zValidator("json", updateUserSchema), async (c) => {
    const user = await usersService.update(c.req.param("id"), c.req.valid("json"));
    return c.json(success(user));
  })
  .delete("/:id", async (c) => {
    await usersService.remove(c.req.param("id"));
    return c.body(null, 204);
  });
