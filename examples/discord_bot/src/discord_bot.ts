// Ext (sidecar) implementation for discord_bot.ktr.
//
// Two thin primitive groups:
//   - AI:      `ai_infer` — one turn against the provider. The conversation
//              history is a Katari value (an `array[turn]`) passed in, so the
//              ext is stateless — no session is held in the sidecar.
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

type AiClient = {
  provider: string;
  model: string;
  api_key: Secret;
};

/** A `data turn(role, text)` value as it arrives from Katari. Either field may
 *  be a content ref if the runtime promoted a large string. */
type KatariTurn = { role: KatariString; text: KatariString };

/** Format a Katari conversation history (an `array[turn]`) into Gemini `contents`. */
async function historyToContents(
  readString: (value: KatariString) => Promise<string>,
  history: RawValue,
): Promise<Turn[]> {
  if (!Array.isArray(history)) {
    throw new Error("ai_infer: history must be an array of turns");
  }
  const contents: Turn[] = [];
  for (const raw of history) {
    const t = raw as KatariTurn;
    const role = (await readString(t.role)) === "model" ? "model" : "user";
    contents.push({ role, parts: [{ text: await readString(t.text) }] });
  }
  return contents;
}

/** generateContent URL + key for an ai_client (gemini only; validates the key). */
function geminiEndpoint(client: AiClient): string {
  if (client.provider !== "gemini") {
    throw new Error(`unsupported provider '${client.provider}' (only 'gemini')`);
  }
  const apiKey = client.api_key?.$secret;
  if (typeof apiKey !== "string" || apiKey === "") {
    throw new Error("missing api key (expected ai_client.api_key as a secret)");
  }
  return (
    `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(client.model)}` +
    `:generateContent?key=${encodeURIComponent(apiKey)}`
  );
}

katari.agent<{ client: AiClient; history: RawValue }>("ai_infer", async (ctx) => {
  const url = geminiEndpoint(ctx.args.client);
  const contents = await historyToContents((v) => ctx.readString(v), ctx.args.history);
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ contents }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`ai_infer: gemini ${res.status}: ${detail}`);
  }
  const data = (await res.json()) as {
    candidates?: { content?: { parts?: { text?: string }[] } }[];
  };
  return (data.candidates?.[0]?.content?.parts ?? []).map((part) => part.text ?? "").join("");
});

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

/** A `data agent_metadata(...)` value (from get_metadata) as it arrives. */
type KatariAgentMetadata = {
  name: KatariString;
  description: KatariString;
  input: KatariString;
};

// One model step: given the conversation + the tools' schemas, return the
// model's decision (a step_final reply, or a step_call naming a tool by INDEX
// into the tools array + the args it chose). The loop that runs the chosen
// tool and feeds its output back lives in Katari (`infer_with_tools`), which
// dispatches the tool by value via call_agent — so the sidecar never touches
// the tool agent values, only their metadata.
katari.agent<{
  client: AiClient;
  history: RawValue;
  tool_metas: RawValue; // array of agent_metadata; tool_metas[i] describes tools[i]
}>("infer_step", async (ctx) => {
  const url = geminiEndpoint(ctx.args.client);

  const toolMetas = ctx.args.tool_metas;
  if (!Array.isArray(toolMetas)) {
    throw new Error("infer_step: tool_metas must be an array");
  }
  const functionDeclarations = await Promise.all(
    toolMetas.map(async (raw) => {
      const meta = raw as KatariAgentMetadata;
      return {
        name: await ctx.readString(meta.name),
        description: await ctx.readString(meta.description),
        parameters: sanitizeSchemaForGemini(JSON.parse(await ctx.readString(meta.input))),
      };
    }),
  );
  const indexByName = new Map(functionDeclarations.map((d, i) => [d.name, i]));

  const contents = await historyToContents((v) => ctx.readString(v), ctx.args.history);
  const res = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ contents, tools: [{ functionDeclarations }] }),
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`infer_step: gemini ${res.status}: ${detail}`);
  }
  const data = (await res.json()) as { candidates?: { content?: Turn }[] };
  const parts = data.candidates?.[0]?.content?.parts ?? [];
  const calls = parts.flatMap((p) => ("functionCall" in p ? [p.functionCall] : []));

  if (calls.length === 0) {
    const text = parts.flatMap((p) => ("text" in p ? [p.text] : [])).join("");
    return { $constructor: "discord_bot.step_final", text } as RawValue;
  }
  // The model wants a tool: report WHICH (by index into the tools array) and
  // the args it produced; Katari validates + dispatches it via call_agent.
  const call = calls[0];
  return {
    $constructor: "discord_bot.step_call",
    tool_index: indexByName.get(call.name) ?? 0,
    args: (call.args ?? {}) as RawValue,
  } as RawValue;
});
