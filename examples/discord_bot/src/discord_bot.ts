// Ext (sidecar) implementation for discord_bot.ktr.
//
// Two thin primitive groups:
//   - AI:      `create_session` / `ai_infer` — one conversation turn against the
//              provider, with the message history held here in the sidecar (the
//              language has no list-append yet, so it can't carry the history).
//   - Discord: `create_discord_client` / `watch_messages` / `send_message` — a
//              live gateway connection kept in the sidecar; `watch_messages`
//              delegates a Katari agent for each human message.
//
// Secrets (the api key, the bot token) arrive as `{ $secret: "<plaintext>" }`:
// the sidecar is inside the runtime's trust boundary, so it legitimately holds
// the cleartext credential.

import { Client, Events, GatewayIntentBits, type Message } from "discord.js";
import katari, { type KatariAgent, type KatariString } from "@katari-lang/port";

type Secret = { $secret: string };

// ── AI ──────────────────────────────────────────────────────────────────────

/** One turn in a conversation, in Gemini's `contents` shape. */
type Turn = { role: "user" | "model"; parts: { text: string }[] };

/** Conversation histories, keyed by session id. Lost on sidecar restart
 *  (acceptable for the example; durable history needs language-side lists). */
const sessions = new Map<string, Turn[]>();

katari.agent("create_session", async () => {
  const id = crypto.randomUUID();
  sessions.set(id, []);
  return id;
});

type AiClient = {
  provider: string;
  model: string;
  api_key: Secret;
};

katari.agent<{ client: AiClient; session: KatariString; prompt: KatariString }>(
  "ai_infer",
  async (ctx) => {
    const { args } = ctx;
    const { client } = args;

    const session = await ctx.readString(args.session);
    const prompt = await ctx.readString(args.prompt);

    if (client.provider !== "gemini") {
      throw new Error(`ai_infer: unsupported provider '${client.provider}' (only 'gemini')`);
    }
    const apiKey = client.api_key?.$secret;
    if (typeof apiKey !== "string" || apiKey === "") {
      throw new Error("ai_infer: missing api key (expected ai_client.api_key as a secret)");
    }

    const history = sessions.get(session) ?? [];
    history.push({ role: "user", parts: [{ text: prompt }] });

    const url =
      `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(client.model)}` +
      `:generateContent?key=${encodeURIComponent(apiKey)}`;
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ contents: history }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      throw new Error(`ai_infer: gemini ${res.status}: ${detail}`);
    }
    const data = (await res.json()) as {
      candidates?: { content?: { parts?: { text?: string }[] } }[];
    };
    const reply = (data.candidates?.[0]?.content?.parts ?? [])
      .map((part) => part.text ?? "")
      .join("");

    history.push({ role: "model", parts: [{ text: reply }] });
    sessions.set(session, history);
    return reply;
  },
);

// ── Discord ───────────────────────────────────────────────────────────────

/** Live gateway connections, keyed by the opaque handle we hand back to Katari.
 *  Long-lived; cleaned up on sidecar restart (the language has no scope-exit
 *  hook to disconnect on its own). */
const discordClients = new Map<string, Client>();

function requireClient(handle: string): Client {
  const client = discordClients.get(handle);
  if (client === undefined) throw new Error(`discord: unknown client handle '${handle}'`);
  return client;
}

katari.agent<{ token: Secret }>("create_discord_client", async ({ args }) => {
  const token = args.token?.$secret;
  if (typeof token !== "string" || token === "") {
    throw new Error("create_discord_client: missing token (expected a secret)");
  }
  const client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
  });
  await new Promise<void>((resolve, reject) => {
    client.once(Events.ClientReady, () => resolve());
    client.once(Events.Error, reject);
    client.login(token).catch(reject);
  });
  const handle = crypto.randomUUID();
  discordClients.set(handle, client);
  return handle;
});

katari.agent<{ client: KatariString; channel_id: KatariString; text: KatariString }>(
  "send_message",
  async (ctx) => {
    const { args } = ctx;
    const client = requireClient(await ctx.readString(args.client));
    const channelId = await ctx.readString(args.channel_id);
    const text = await ctx.readString(args.text);
    const channel = await client.channels.fetch(channelId);
    if (channel === null || !channel.isTextBased() || !("send" in channel)) {
      throw new Error(`send_message: channel '${channelId}' is not a text channel`);
    }
    await channel.send(text);
    return null;
  },
);

katari.agent<{ client: KatariString; channel_id: KatariString; on_message: KatariAgent }>(
  "watch_messages",
  async (ctx) => {
    const { args, signal } = ctx;
    const client = requireClient(await ctx.readString(args.client));
    const channelId = await ctx.readString(args.channel_id);
    const onMessage = args.on_message;

    const listener = (message: Message): void => {
      if (message.author.bot) return; // ignore bots, including ourselves
      if (message.channelId !== channelId) return; // only the watched channel
      const text = message.content;
      if (text === "") return;
      // `ctx` carries this delegation's id, so the child is parented correctly
      // even though discord.js fires this listener off our async chain.
      void ctx.delegate(onMessage, { text, channel_id: message.channelId });
    };
    client.on(Events.MessageCreate, listener);

    // Never returns on its own; settles only when the run is cancelled. The
    // cancel cascade reaches us as `signal.abort` — disconnect the gateway then
    // (a handle-scope exit has no cleanup hook, so this is where the client dies).
    return new Promise<null>((_resolve, reject) => {
      signal.addEventListener("abort", () => {
        client.off(Events.MessageCreate, listener);
        void client.destroy();
        reject(new Error("watch_messages: terminated"));
      });
    });
  },
);
