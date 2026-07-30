// HTTP contract for the credential resource: list and forget. The value itself never crosses this
// surface — a credential is deposited by the runtime-hosted OAuth flow and read only by the transport.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const credentialParamSchema = projectIdParamSchema.extend({ name: z.string().min(1) });

/** The proactive-login body: an mcp-profile login supplies the server `url`; a configured-profile login
 *  sends no body (the acquisition profile is decided by the url's presence). `.optional()` on the whole
 *  body admits an absent request body (a configured login) — the flow reads `url` (undefined → configured). */
// http(s) only: the url drives SDK discovery fetches, so a non-network scheme has no meaning here and an
// unconstrained one is just an extra way to aim the runtime somewhere it should not go.
export const credentialLoginBodySchema = z
  .object({ url: z.url({ protocol: /^https?$/ }).optional() })
  .optional();
