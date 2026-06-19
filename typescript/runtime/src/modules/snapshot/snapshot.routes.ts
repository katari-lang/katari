import { Hono } from "hono";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import { rejectReservedModuleNames } from "./snapshot.middleware.js";
import {
  deploySnapshotSchema,
  projectIdParamSchema,
  snapshotParamSchema,
} from "./snapshot.schema.js";
import { snapshotService } from "./snapshot.service.js";

// `/snapshots/head` is registered before `/snapshots/:snapshotId` so the literal segment wins.
export const snapshotRoutes = new Hono<AppEnv>()
  .post(
    "/projects/:projectId/snapshots",
    requireJsonBody,
    rejectReservedModuleNames,
    zValidator("param", projectIdParamSchema),
    zValidator("json", deploySnapshotSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      const result = await snapshotService.deploy(projectId, c.req.valid("json"));
      return c.json(success(result), 201);
    },
  )
  .get(
    "/projects/:projectId/snapshots/head",
    zValidator("param", projectIdParamSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(success(await snapshotService.head(projectId)));
    },
  )
  .get("/projects/:projectId/snapshots", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await snapshotService.list(projectId)));
  })
  .get(
    "/projects/:projectId/snapshots/:snapshotId",
    zValidator("param", snapshotParamSchema),
    async (c) => {
      const { projectId, snapshotId } = c.req.valid("param");
      return c.json(success(await snapshotService.getById(projectId, snapshotId)));
    },
  );
