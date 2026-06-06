// Generic HTTP POST — the ONLY network helper the AI layer needs. Every
// provider's request/response shaping lives in Katari (the ai.gemini /
// ai.openai modules build + parse JSON directly), so this is fully provider-
// agnostic: it POSTs a body and injects the API key as one configurable auth
// header (Authorization: Bearer … for OpenAI, x-goog-api-key: … for Gemini).

import katari, { type KatariString } from "@katari-lang/port";

type Secret = { $secret: string };

katari.agent<{
  url: KatariString;
  body: KatariString;
  auth_header_name: KatariString;
  auth_prefix: KatariString;
  api_key: Secret;
}>("http_post", async (ctx) => {
  const { args } = ctx;
  const url = await ctx.readString(args.url);
  const body = await ctx.readString(args.body);
  const headerName = await ctx.readString(args.auth_header_name);
  const prefix = await ctx.readString(args.auth_prefix);
  const key = args.api_key?.$secret;
  if (typeof key !== "string" || key === "") {
    throw new Error("http_post: missing api key (expected api_key as a secret)");
  }
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", [headerName]: `${prefix}${key}` },
    body,
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`http_post: ${res.status}: ${detail}`);
  }
  return res.text();
});
