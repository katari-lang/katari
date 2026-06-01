# discord_bot

A Discord chat bot, written in Katari. It listens to a channel, asks Gemini
for a reply, and posts it back — built to dogfood the language and SDK.

## How it's put together

- **`src/discord_bot.ktr`** — the agents.
  - `ai_client` is a `data` value (provider + model + a `secret` api key),
    handed to the whole program once through the `get_ai_client` capability.
    The Discord connection is shared the same way via `get_discord_client`.
  - `main` opens both, then calls `watch_messages` and serves forever.
  - For each incoming message the ext delegates `handle_message`, which opens a
    fresh conversation `session`, calls `infer`, and posts the reply. The
    capabilities flow into that delegated agent automatically — `handle_message`
    just declares `with get_ai_client, get_discord_client`.
- **`src/discord_bot.ts`** — the ext (a JS sidecar) with the thin primitives:
  the Gemini HTTP call (`ai_infer`, holding each conversation's history here),
  and the discord.js gateway client (`create_discord_client` / `watch_messages`
  / `send_message`).

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

5. **Deploy and run:**

   ```sh
   katari apply                          # compile + bundle the ext + upload
   katari run discord_bot.main --args '{}'
   ```

   `main` never returns on its own — the bot stays up until you cancel the run.
   Message the bot in your server and it replies.

The runtime listens on `http://localhost:8000` by default; point the CLI at it
with `--api` or `KATARI_API_URL`.
