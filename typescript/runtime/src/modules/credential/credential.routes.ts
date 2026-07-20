import { type Context, Hono } from "hono";
import { BadRequestError } from "../../lib/errors.js";
import { projectIdParamSchema } from "../../lib/params.js";
import { success } from "../../lib/response.js";
import { zValidator } from "../../lib/validation.js";
import type { AppEnv } from "../../types/app-env.js";
import { authorizationFlow } from "../oauth/oauth.service.js";
import { credentialLoginBodySchema, credentialParamSchema } from "./credential.schema.js";
import { credentialService } from "./credential.service.js";

/** Read the optional `url` from a proactive-login request, tolerating an ABSENT body: a configured login
 *  sends none (the acquisition profile is decided by the url's presence). The routing reads the PARSED
 *  body, never a header — a chunked request has no Content-Length, and keying on it would silently route
 *  an mcp `{ url }` body to the configured profile. An empty body is the configured login; a non-empty
 *  body must be valid JSON of the login shape (a malformed one — bad JSON, a non-url `url` — is a 400,
 *  never silently dropped). */
async function loginUrlOf(c: Context<AppEnv>): Promise<string | undefined> {
  const raw = await c.req.text();
  if (raw.trim() === "") return undefined;
  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    throw new BadRequestError("the login body is not valid JSON; expected an optional { url }");
  }
  const parsed = credentialLoginBodySchema.safeParse(body);
  if (!parsed.success) {
    throw new BadRequestError("the login body is malformed; expected an optional { url }");
  }
  return parsed.data?.url;
}

export const credentialRoutes = new Hono<AppEnv>()
  .get("/projects/:projectId/credentials", zValidator("param", projectIdParamSchema), async (c) => {
    const { projectId } = c.req.valid("param");
    return c.json(success(await credentialService.list(projectId)));
  })
  // Proactive login: start the runtime-hosted flow for a credential BY NAME (before any run needs it, or
  // to re-authorize). An mcp login supplies the server `url` in the body; a configured login sends none
  // (the profile is decided by the url's presence). Returns the authorization URL for the caller to open.
  .post(
    "/projects/:projectId/credentials/:name/login",
    zValidator("param", credentialParamSchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      return c.json(
        success(await authorizationFlow.startForCredential(projectId, name, await loginUrlOf(c))),
      );
    },
  )
  .delete(
    "/projects/:projectId/credentials/:name",
    zValidator("param", credentialParamSchema),
    async (c) => {
      const { projectId, name } = c.req.valid("param");
      await credentialService.delete(projectId, name);
      return c.body(null, 204);
    },
  );
