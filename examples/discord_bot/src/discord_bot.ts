// Sidecar entry for discord_bot. Deliberately thin: it only pulls in the split,
// provider-agnostic primitive groups, each of which registers its handlers on
// import. There is NO AI-provider code here anymore — every request/response
// shaping for Gemini / OpenAI lives in Katari (the discord_bot.ai.gemini /
// .openai modules build + parse JSON directly), and the only network helper is
// the generic `http_post`. Each group could move to its own package unchanged.
//
// Secrets (api keys, the bot token) arrive as `{ $secret: "<plaintext>" }`: the
// sidecar is inside the runtime's trust boundary, so it legitimately holds the
// cleartext credential.

import "./sidecar/http.js";
import "./sidecar/discord.js";
import "./sidecar/e2b.js";
