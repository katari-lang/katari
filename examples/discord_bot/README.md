# discord_bot

A Discord chat bot, written in Katari. It listens to a channel, asks Gemini
for a reply, and posts it back — built to dogfood the language and SDK.

## How it's put together

- **`src/discord_bot.ktr`** — the agents.
  - `ai_client` is a `data` value (provider + model + a `secret` api key),
    handed to the whole program once through the `get_ai_client` capability.
    The Discord connection and the conversation `session` are shared the same
    way (`get_discord_client` / `get_session`).
  - `watch_messages(channel_id)` serves a channel forever, raising an
    `on_message(text, channel_id)` **request** for each message. `main` provides
    the capabilities, then installs a `handle { request on_message(...) { ... } }`
    that does the work — calls `infer`, posts the reply with `send_message`,
    `next`s to keep serving. Because the session is opened once at the top, the
    bot keeps conversation history across messages.
  - This is the point of the request model: `watch_messages` only knows it
    raises `on_message`; what the reaction *does* (and which capabilities it
    needs) lives in the user's handler, not in the watch signature.
- **`src/discord_bot.ts`** — the ext (a JS sidecar) with the thin primitives:
  the Gemini HTTP call (`ai_infer`, holding each conversation's history here),
  and the discord.js gateway client (`create_discord_client` / `discord_watch` /
  `discord_send`, which the ktr wraps as the capability agents `watch_messages` /
  `send_message`).

## Setup

1. **Create a Discord bot.** In the
   [Developer Portal](https://discord.com/developers/applications): create an
   application → **Bot** → copy the token. Under **Privileged Gateway Intents**,
   enable **Message Content Intent** (the bot reads message text). Invite the
   bot to a server with the `bot` scope and the *Send Messages* /
   *Read Message History* permissions.

2. **Get a Gemini API key** from [Google AI Studio](https://aistudio.google.com/apikey).

3. **Start the runtime:**

   ```sh
   cp .env.example .env      # then edit KATARI_API_KEY / KATARI_SECRET_KEY for prod
   docker compose up -d
   ```

4. **Store the two agent secrets** in the runtime (these are read at run time by
   `get_secret_env`, encrypted at rest — they are *not* the `.env` above). In the
   admin UI's **Env** page, add:

   - `GEMINI_API_KEY`
   - `DISCORD_TOKEN`
   - `E2B_API_KEY` (only needed for the Python-tool demo below)

5. **Deploy and run:**

   ```sh
   katari apply                                          # compile + bundle the ext + upload
   katari run discord_bot.main --args '{"channel_id": "<channel id>"}'
   ```

   `main` never returns on its own — the bot stays up until you cancel the run.
   Message the bot in that channel and it replies.

## Tool calling (run Python via e2b)

`ask` lets the model call a `run_python` tool: the ext runs the tool-call
feedback loop, dispatching the tool back into Katari (so the tool is just an
agent — it can use capabilities, raise requests, …). `solve` is a standalone
entry to try it without Discord:

```sh
katari run discord_bot.solve --wait \
  --args '{"task": "Use Python to compute the sum of the first 100 primes."}'
```

Today it wires one tool (`run_python`); the loop is written list-shaped, so the
next step is to pass an array of tools (blocked on language-side list ops).

The runtime listens on `http://localhost:8000` by default; point the CLI at it
with `--api` or `KATARI_API_URL`.
