// The public MCP serve endpoint: `POST /mcp/:token` — the URLs `mcp.serve` mints. It lives OUTSIDE the
// bearer-authenticated `/api` surface (an external MCP client cannot present the runtime's key); the
// unguessable token is the capability, and the durable `mcp_serve_instances` row scopes it to exactly
// one endpoint of one project.
//
// The endpoint is STATELESS streamable-HTTP: POST-only JSON responses, no session id, no SSE stream —
// so `GET` / `DELETE` answer 405 (the SDK client tolerates a 405 on its optional notification stream).
// The JSON-RPC mapping itself lives in `mcp-serve.ts`; this route only reads the body and writes the
// handler's reply (404 = no endpoint serves this token, 410 = winding down, 202 = notification ack).

import type { Context } from "hono";
import { Hono } from "hono";
import { facade } from "../../runtime/facade.js";
import type { AppEnv } from "../../types/app-env.js";

/** The stateless contract has no server-to-client stream and no session to delete. */
function methodNotAllowed(c: Context<AppEnv>) {
  return c.json(
    { error: "MCP serve endpoints are POST-only (stateless JSON responses; no SSE, no session)" },
    405,
    { Allow: "POST" },
  );
}

export const mcpServeRoutes = new Hono<AppEnv>()
  .post("/:token", async (c) => {
    const reply = await facade.deliverMcp({
      token: c.req.param("token"),
      body: await c.req.text(),
    });
    // A notification's ack carries no body; every other reply is a JSON-RPC response, serialised by
    // hand like the webhook route (the recursive `Json` type blows up Hono's typed `c.json`).
    if (reply.body === null) return c.body(null, 202);
    return c.newResponse(JSON.stringify(reply.body), reply.status, {
      "Content-Type": "application/json",
    });
  })
  .get("/:token", methodNotAllowed)
  .delete("/:token", methodNotAllowed);
