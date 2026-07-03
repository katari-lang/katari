// The sidecar half of `discord.ktr` — the discord.js gateway client. Handlers register under this
// file's module path (`discord_bot.discord.*`). Clients live in a module-level map for the sidecar
// process's lifetime (one process per snapshot), keyed by the opaque handle Katari carries around.

import { katari, type KatariAgent } from "@katari-lang/port";
import { Client, Events, GatewayIntentBits } from "discord.js";

const clients = new Map<string, Client>();
let nextHandle = 1;

katari.agent<{ token: string }>("create_discord_client", async ({ token }) => {
  const client = new Client({
    intents: [
      GatewayIntentBits.Guilds,
      GatewayIntentBits.GuildMessages,
      GatewayIntentBits.MessageContent,
    ],
  });
  await client.login(token);
  const handle = `discord-${nextHandle}`;
  nextHandle += 1;
  clients.set(handle, client);
  return handle;
});

katari.agent<{ client: string; channel_id: string; text: string }>(
  "discord_send",
  async ({ client, channel_id, text }) => {
    const channel = await connectionOf(client).channels.fetch(channel_id);
    if (channel === null || !channel.isSendable()) {
      throw new Error(`channel ${channel_id} is not a sendable text channel`);
    }
    await channel.send(text);
    return null;
  },
);

katari.agent<{ client: string; channel_id: string; deliver_to: KatariAgent }>(
  "discord_watch",
  ({ client, channel_id, deliver_to }, context) => {
    const connection = connectionOf(client);
    return new Promise<never>((_resolve, reject) => {
      const listener = (message: { author: { bot: boolean }; channelId: string; content: string }) => {
        if (message.author.bot || message.channelId !== channel_id) return;
        // Deliver back into the runtime as an inner delegation; the callback's `on_message`
        // request escalates through this call to the app's handler. A delivery failure tears the
        // watch down (the app's panic clause reports it).
        deliver_to.call({ text: message.content, channel_id: message.channelId }).catch((error) => {
          cleanup();
          reject(error instanceof Error ? error : new Error(String(error)));
        });
      };
      const cleanup = () => connection.off(Events.MessageCreate, listener);
      connection.on(Events.MessageCreate, listener);
      // The runtime cancelled the call (run cancel / teardown): stop listening and settle.
      context.signal.addEventListener("abort", () => {
        cleanup();
        reject(new Error("discord watch cancelled"));
      });
    });
  },
);

function connectionOf(handle: string): Client {
  const connection = clients.get(handle);
  if (connection === undefined) {
    throw new Error(`unknown discord client handle: ${handle}`);
  }
  return connection;
}
