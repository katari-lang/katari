import { startServer } from "katari-protocol";
import type { AgentHandlerFn, JsonValue } from "katari-protocol";
import {
  Client,
  GatewayIntentBits,
  type TextChannel,
  type Message as DiscordMessage,
} from "discord.js";

// ===========================================================================
// Discord client (shared singleton)
// ===========================================================================

const token = process.env.DISCORD_TOKEN;
if (!token) {
  console.error("DISCORD_TOKEN is required");
  process.exit(1);
}

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

const readyPromise = new Promise<void>((resolve) => {
  client.once("ready", () => {
    console.log(`Discord bot logged in as ${client.user?.tag}`);
    resolve();
  });
});

client.login(token);

// ===========================================================================
// Helpers
// ===========================================================================

async function getTextChannel(channelId: string): Promise<TextChannel> {
  await readyPromise;
  const channel = await client.channels.fetch(channelId);
  if (!channel?.isTextBased()) {
    throw new Error(`Channel ${channelId} is not a text channel`);
  }
  return channel as TextChannel;
}

function formatMessage(msg: DiscordMessage): JsonValue {
  return {
    id: msg.id,
    channel_id: msg.channelId,
    author: msg.author.username,
    content: msg.content,
    is_bot: msg.author.bot,
  };
}

// ===========================================================================
// Handlers
// ===========================================================================

const watchChannel: AgentHandlerFn = async (args, ctx) => {
  const channelId = args[0] as string;
  await readyPromise;

  // Long-running: listen for messages and fire on_message requests
  const listener = (msg: DiscordMessage) => {
    if (msg.channelId === channelId) {
      ctx.sendRequest("on_message", [formatMessage(msg)]);
    }
  };

  client.on("messageCreate", listener);

  // Never resolves — agent stays alive
  return new Promise(() => {});
};

const sendMessage: AgentHandlerFn = async (args) => {
  const channelId = args[0] as string;
  const content = args[1] as string;

  const channel = await getTextChannel(channelId);
  const msg = await channel.send(content);
  return msg.id as JsonValue;
};

const replyTo: AgentHandlerFn = async (args) => {
  const channelId = args[0] as string;
  const messageId = args[1] as string;
  const content = args[2] as string;

  const channel = await getTextChannel(channelId);
  const targetMsg = await channel.messages.fetch(messageId);
  const reply = await targetMsg.reply(content);
  return reply.id as JsonValue;
};

const fetchMessages: AgentHandlerFn = async (args) => {
  const channelId = args[0] as string;
  const limit = args[1] as number;

  const channel = await getTextChannel(channelId);
  const messages = await channel.messages.fetch({ limit });
  const result = messages.map(formatMessage);
  return Array.from(result.values()) as unknown as JsonValue;
};

// ===========================================================================
// Start
// ===========================================================================

const port = parseInt(process.env.PORT ?? "8001", 10);
const selfBaseUrl = process.env.KATARI_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: {
    watch_channel: watchChannel,
    send_message: sendMessage,
    reply_to: replyTo,
    fetch_messages: fetchMessages,
  },
});
