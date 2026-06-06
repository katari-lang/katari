// Discord gateway primitives: a live discord.js client kept in the sidecar
// (returned to Katari as an opaque handle), plus send / watch. `discord_watch`
// delegates the callback agent for each human message. (The ktr wraps these as
// the capability agents watch_messages / send_message.)

import { Client, Events, GatewayIntentBits, type Message } from "discord.js";
import katari, { type KatariAgent, type KatariString } from "@katari-lang/port";

type Secret = { $secret: string };

// Live gateway connections, keyed by the opaque handle we hand back to Katari.
// Long-lived; cleaned up on sidecar restart or cancel (the language has no
// scope-exit hook, so the watch's abort path disconnects).
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
  "discord_send",
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
  "discord_watch",
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
