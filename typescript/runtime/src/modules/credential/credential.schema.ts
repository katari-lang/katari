// HTTP contract for the credential resource: list and forget. The value itself never crosses this
// surface — a credential is deposited by the runtime-hosted OAuth flow and read only by the transport.

import { z } from "zod";
import { projectIdParamSchema } from "../../lib/params.js";

export const credentialParamSchema = projectIdParamSchema.extend({ name: z.string().min(1) });
