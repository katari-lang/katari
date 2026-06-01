// Ext (sidecar) implementation for discord_bot.ktr.
//
// Two thin primitive groups:
//   - AI:      `create_session` / `ai_infer` — one conversation turn against the
//              provider, with the message history held here in the sidecar (the
//              language has no list-append yet, so it can't carry the history).
//   - Discord: `create_discord_client` / `discord_watch` / `discord_send` — a
//              live gateway connection kept in the sidecar; `discord_watch`
//              delegates a callback agent for each human message. (The ktr wraps
//              these as the capability agents watch_messages / send_message.)
//
// Secrets (the api key, the bot token) arrive as `{ $secret: "<plaintext>" }`:
// the sidecar is inside the runtime's trust boundary, so it legitimately holds
// the cleartext credential.

import { Sandbox } from "@e2b/code-interpreter";
import { Client, Events, GatewayIntentBits, type Message } from "discord.js";
import katari, { type KatariAgent, type KatariString, type RawValue } from "@katari-lang/port";

type Secret = { $secret: string };

// ── AI ──────────────────────────────────────────────────────────────────────

/** One part of a Gemini turn: plain text, a tool call, or a tool result. */
type GeminiPart =
  | { text: string }
  | { functionCall: { name: string; args: Record<string, RawValue> } }
  | { functionResponse: { name: string; response: { result: string } } };

/** One turn in a conversation, in Gemini's `contents` shape. */
type Turn = { role: "user" | "model"; parts: GeminiPart[] };

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

// ── Tools (e2b + the tool-call loop) ────────────────────────────────────────

katari.agent<{ code: KatariString; api_key: Secret }>("e2b_exec", async (ctx) => {
  const code = await ctx.readString(ctx.args.code);
  const apiKey = ctx.args.api_key?.$secret;
  if (typeof apiKey !== "string" || apiKey === "") {
    throw new Error("e2b_exec: missing api key (expected api_key as a secret)");
  }
  const sandbox = await Sandbox.create({ apiKey });
  try {
    const execution = await sandbox.runCode(code);
    const out: string[] = [];
    const stdout = execution.logs.stdout.join("");
    if (stdout !== "") out.push(stdout.trimEnd());
    if (execution.text != null && execution.text !== "") out.push(`=> ${execution.text}`);
    if (execution.error) out.push(`ERROR ${execution.error.name}: ${execution.error.value}`);
    const stderr = execution.logs.stderr.join("");
    if (stderr !== "") out.push(`stderr: ${stderr.trimEnd()}`);
    return out.length > 0 ? out.join("\n") : "(no output)";
  } finally {
    await sandbox.kill();
  }
});

/** A tool the model can call: its function-declaration for Gemini + the Katari
 *  agent to dispatch when the model calls it. */
type ToolSpec = {
  name: string;
  description: string;
  parameters: unknown; // JSON Schema object (from get_metadata's `input`)
  agent: KatariAgent;
};

const GEMINI_TOOL_MAX_STEPS = 8;

// The compiler emits a correct draft-07 JSON Schema, but Gemini's
// functionDeclarations.parameters only accepts an OpenAPI subset and 400s on
// keywords like `additionalProperties` / `$schema`. Strip those per-provider
// (the schema stays draft-07 everywhere else — this is just the Gemini wire).
const GEMINI_UNSUPPORTED_SCHEMA_KEYS = new Set([
  "additionalProperties",
  "$schema",
  "$id",
  "$defs",
  "definitions",
]);
function sanitizeSchemaForGemini(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(sanitizeSchemaForGemini);
  if (node !== null && typeof node === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, value] of Object.entries(node)) {
      if (GEMINI_UNSUPPORTED_SCHEMA_KEYS.has(key)) continue;
      out[key] = sanitizeSchemaForGemini(value);
    }
    return out;
  }
  return node;
}

katari.agent<{
  client: AiClient;
  session: KatariString;
  prompt: KatariString;
  tool_name: KatariString;
  tool_description: KatariString;
  tool_input: KatariString;
  tool: KatariAgent;
}>("infer_with_tools", async (ctx) => {
  const { client } = ctx.args;
  const session = await ctx.readString(ctx.args.session);
  const prompt = await ctx.readString(ctx.args.prompt);

  // v0: exactly one tool. v1 = build this list from `tools: array of agent`,
  // mapping get_metadata over each. The loop below is already list-shaped.
  const tools: ToolSpec[] = [
    {
      name: await ctx.readString(ctx.args.tool_name),
      description: await ctx.readString(ctx.args.tool_description),
      parameters: sanitizeSchemaForGemini(JSON.parse(await ctx.readString(ctx.args.tool_input))),
      agent: ctx.args.tool,
    },
  ];
  const byName = new Map(tools.map((t) => [t.name, t]));
  const functionDeclarations = tools.map((t) => ({
    name: t.name,
    description: t.description,
    parameters: t.parameters,
  }));

  if (client.provider !== "gemini") {
    throw new Error(`infer_with_tools: unsupported provider '${client.provider}' (only 'gemini')`);
  }
  const apiKey = client.api_key?.$secret;
  if (typeof apiKey !== "string" || apiKey === "") {
    throw new Error("infer_with_tools: missing api key (expected ai_client.api_key as a secret)");
  }
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(client.model)}` +
    `:generateContent?key=${encodeURIComponent(apiKey)}`;

  const history = sessions.get(session) ?? [];
  history.push({ role: "user", parts: [{ text: prompt }] });

  for (let step = 0; step < GEMINI_TOOL_MAX_STEPS; step++) {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ contents: history, tools: [{ functionDeclarations }] }),
    });
    if (!res.ok) {
      const detail = await res.text().catch(() => "");
      throw new Error(`infer_with_tools: gemini ${res.status}: ${detail}`);
    }
    const data = (await res.json()) as {
      candidates?: { content?: Turn }[];
    };
    const content = data.candidates?.[0]?.content;
    const parts = content?.parts ?? [];
    const calls = parts.flatMap((p) => ("functionCall" in p ? [p.functionCall] : []));

    if (calls.length === 0) {
      const text = parts.flatMap((p) => ("text" in p ? [p.text] : [])).join("");
      if (content) history.push(content);
      sessions.set(session, history);
      return text;
    }

    // Record the model's tool-call turn, run each tool, feed the results back.
    if (content) history.push(content);
    const responseParts: GeminiPart[] = [];
    for (const call of calls) {
      const spec = byName.get(call.name);
      let result: string;
      if (spec === undefined) {
        result = `error: unknown tool '${call.name}'`;
      } else {
        const raw = await ctx.delegate(spec.agent, call.args ?? {});
        result = typeof raw === "string" ? raw : JSON.stringify(raw);
      }
      responseParts.push({ functionResponse: { name: call.name, response: { result } } });
    }
    history.push({ role: "user", parts: responseParts });
    sessions.set(session, history);
  }

  return `(stopped: the model kept calling tools past ${GEMINI_TOOL_MAX_STEPS} steps)`;
});
