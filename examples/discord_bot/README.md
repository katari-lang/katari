# discord_bot — a tool-using AI Discord bot

The composition example: everything in [`playground`](../playground) working together in one app.

- **Provider-agnostic AI layer** ([`ai.ktr`](src/discord_bot/ai.ktr) + [`ai/types.ktr`](src/discord_bot/ai/types.ktr)):
  the conversation/step vocabulary, one `ai_client` union, and the tool-calling loop written *in
  Katari* — schemas derived with `ai.get_metadata`, tool batches dispatched concurrently with
  `parallel for`, each call validated against the tool's schema by `ai.call_agent`.
- **Two providers** ([`ai/gemini.ktr`](src/discord_bot/ai/gemini.ktr), [`ai/openai.ktr`](src/discord_bot/ai/openai.ktr)):
  request bodies built and responses parsed as `json` values in Katari; the only network call is
  [`api.post_json`](src/discord_bot/api.ktr), a thin wrapper over the built-in `http.fetch`
  (no HTTP sidecar at all). Swap providers by editing one line in `make_client`.
- **Discord gateway** ([`discord.ktr`](src/discord_bot/discord.ktr) + [`discord.ts`](src/discord_bot/discord.ts)):
  a discord.js client in the FFI sidecar. Incoming messages come back through an **inner
  delegation** (`deliver_to.call(...)`) and surface as the `on_message` request, which the app
  handles with a **stateful handler** holding the conversation history as a Katari value.
- **e2b tool** ([`e2b.ktr`](src/discord_bot/e2b.ktr) + [`e2b.ts`](src/discord_bot/e2b.ts)): run
  Python in a sandbox; its API key rides the `get_e2b_key` capability, provided once at the root.
- **Secrets**: API keys are runtime env entries read with `env.get_secret` — private values that
  can flow into an http auth header or an FFI call, but never out to a user-facing boundary.

## Run it

With the runtime up and the repo's toolchain built (see the repo README):

```sh
# The runtime URL comes from katari.toml's [runtime].url. The CLI authenticates with the runtime's
# KATARI_API_KEY (the same one in the repo `.env`), so export it once:
export KATARI_API_KEY="$(grep -m1 '^KATARI_API_KEY=' ../../.env | cut -d= -f2-)"
cd examples/discord_bot

# Secrets live in the runtime, not in files:
katari env set GEMINI_API_KEY  --secret   # or OPENAI_API_KEY + edit make_client
katari env set E2B_API_KEY     --secret
katari env set DISCORD_TOKEN   --secret   # bot token with the MESSAGE CONTENT intent

katari apply

# Tool loop only, no Discord (asks Gemini, runs Python via e2b when the model wants to):
katari run discord_bot.solve --arg '{"task":"What is 2^100? Use python."}'

# The bot: serve one channel until cancelled.
katari run discord_bot.main --arg '{"channel_id":"<your channel id>"}'
```

While `main` runs, the console's run page shows the delegation tree: the gateway watch (an FFI
call), and each incoming message spawning its inner `deliver` → `on_message` → provider-fetch
chain under it.
