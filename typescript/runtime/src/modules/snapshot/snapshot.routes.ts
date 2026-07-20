import { Hono } from "hono";
import { projectIdParamSchema } from "../../lib/params.js";
import { pagedList, success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import { requireJsonBody } from "../../middleware/require-json.js";
import type { AppEnv } from "../../types/app-env.js";
import { screenRawDeployBody } from "./snapshot.middleware.js";
import {
  deploySnapshotSchema,
  listSnapshotsQuerySchema,
  setHeadSchema,
  snapshotParamSchema,
} from "./snapshot.schema.js";
import { snapshotService } from "./snapshot.service.js";

// `/snapshots/head` is registered before `/snapshots/:snapshotId` so the literal segment wins.
export const snapshotRoutes = new Hono<AppEnv>()
  .post(
    "/projects/:projectId/snapshots",
    requireJsonBody,
    screenRawDeployBody,
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
  // Rollback (or roll-forward): move the live head to an existing snapshot. Runs pin the snapshot they
  // started on, so only new runs follow the moved head.
  .put(
    "/projects/:projectId/snapshots/head",
    requireJsonBody,
    zValidator("param", projectIdParamSchema),
    zValidator("json", setHeadSchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      const { snapshotId } = c.req.valid("json");
      return c.json(success(await snapshotService.setHead(projectId, snapshotId)));
    },
  )
  .get(
    "/projects/:projectId/snapshots",
    zValidator("param", projectIdParamSchema),
    zValidator("query", listSnapshotsQuerySchema),
    async (c) => {
      const { projectId } = c.req.valid("param");
      return c.json(pagedList(c, await snapshotService.list(projectId, c.req.valid("query"))));
    },
  )
  .get(
    "/projects/:projectId/snapshots/:snapshotId",
    zValidator("param", snapshotParamSchema),
    async (c) => {
      const { projectId, snapshotId } = c.req.valid("param");
      return c.json(success(await snapshotService.getById(projectId, snapshotId)));
    },
  );
