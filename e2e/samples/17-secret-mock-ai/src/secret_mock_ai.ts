// Sidecar for 17-secret-mock-ai. Implements the user-defined
// `http_request` ext agent.
//
// The `auth` parameter is declared as `secret` in main.ktr, so on
// the IPC wire it arrives as `{ "$secret": "<plaintext>" }` — the
// sidecar lives inside the runtime's trust boundary and is the only
// party that legitimately handles the cleartext credential (= what
// a real HTTP client would put in an Authorization header).
//
// For the mock we just echo the URL + the secret string so the
// e2e test can verify the secret value reached this side intact.

import type { RawValue } from "@katari-lang/port";
import katari from "@katari-lang/port";

katari.agent("http_request", async ({ args }) => {
  const url = args["url"] as string;
  const auth = args["auth"] as { $secret: string };
  if (typeof auth !== "object" || auth === null || typeof auth.$secret !== "string") {
    throw new Error(
      `http_request: expected auth to arrive as { $secret } envelope, got ${JSON.stringify(auth)}`,
    );
  }
  const body = `GET ${url} (auth=${auth.$secret})`;
  return body satisfies RawValue;
});
