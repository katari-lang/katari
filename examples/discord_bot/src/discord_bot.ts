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
import katari, {
  isKatariString,
  type KatariAgent,
  type KatariString,
  type RawValue,
} from "@katari-lang/port";

type Secret = { $secret: string };

// ── AI ──────────────────────────────────────────────────────────────────────

/** One part of a Gemini turn: plain text, a tool call, or a tool result.
 *  Gemini 3 attaches a `thoughtSignature` (an opaque token tied to the model's
 *  reasoning) to functionCall parts; it MUST be replayed verbatim on the next
 *  request or the API 400s ("Function call is missing a thought_signature"). */
type GeminiPart =
  | { text: string }
  | {
      functionCall: { name: string; args: Record<string, RawValue> };
      thoughtSignature?: string;
    }
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

/** Deep-resolve any KatariString (inline or `$ref`) nested in a model-produced
 *  args object, so the echoed `functionCall` carries plain JSON (the runtime may
 *  have promoted a large string field — e.g. code — to a content ref). */
async function resolveDeep(
  readString: (value: KatariString) => Promise<string>,
  value: RawValue,
): Promise<RawValue> {
  if (isKatariString(value)) return readString(value);
  if (Array.isArray(value)) return Promise.all(value.map((v) => resolveDeep(readString, v)));
  if (value !== null && typeof value === "object") {
    const out: Record<string, RawValue> = {};
    for (const [key, v] of Object.entries(value as Record<string, RawValue>)) {
      out[key] = await resolveDeep(readString, v);
    }
    return out;
  }
  return value;
}

/** Format a Katari conversation history (`array[message]`) into Gemini
 *  `contents`. A `turn` is plain text; a `call_turn` replays the model's
 *  `functionCall` parts; a `result_turn` carries `functionResponse` parts — so
 *  the function-calling loop CLOSES (the model sees its own call + the tool
 *  output) instead of re-calling the tool forever. */
async function historyToContents(
  readString: (value: KatariString) => Promise<string>,
  history: RawValue,
): Promise<Turn[]> {
  if (!Array.isArray(history)) {
    throw new Error("ai_infer: history must be an array of messages");
  }
  const contents: Turn[] = [];
  for (const raw of history) {
    const ctor = (raw as Record<string, RawValue>).$constructor;
    if (ctor === "discord_bot.call_turn") {
      const calls = (raw as { calls?: RawValue }).calls;
      const list = Array.isArray(calls) ? calls : [];
      const parts = await Promise.all(
        list.map(async (c) => {
          const call = c as Record<string, RawValue>;
          const signature =
            call.thought_signature !== undefined
              ? await readString(call.thought_signature as KatariString)
              : "";
          const part: GeminiPart = {
            functionCall: {
              name: await readString(call.name as KatariString),
              args: (await resolveDeep(readString, call.args ?? {})) as Record<string, RawValue>,
            },
          };
          // Replay the model's thought signature verbatim (Gemini 3 requires it).
          if (signature !== "") part.thoughtSignature = signature;
          return part;
        }),
      );
      contents.push({ role: "model", parts });
    } else if (ctor === "discord_bot.result_turn") {
      const results = (raw as { results?: RawValue }).results;
      const list = Array.isArray(results) ? results : [];
      const parts = await Promise.all(
        list.map(async (r) => {
          const result = r as Record<string, RawValue>;
          return {
            functionResponse: {
              name: await readString(result.name as KatariString),
              response: { result: await readString(result.text as KatariString) },
            },
          };
        }),
      );
      contents.push({ role: "user", parts });
    } else {
      const t = raw as KatariTurn;
      const role = (await readString(t.role)) === "model" ? "model" : "user";
      contents.push({ role, parts: [{ text: await readString(t.text) }] });
    }
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
// model's decision (a step_final reply, or a step_call carrying a BATCH of tool
// calls — each naming a tool by INDEX into the tools array + the args it chose).
// The loop that runs the chosen tools and feeds their output back lives in
// Katari (`infer_with_tools`), which dispatches each tool by value via
// call_agent — so the sidecar never touches the tool agent values, only their
// metadata. Gemini routinely emits several functionCall parts in one turn; we
// pass them all through and let Katari fan them out with `parallel for`.
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
  // Keep each functionCall WITH its thoughtSignature — Gemini 3 requires it
  // replayed on the model turn we feed back next step.
  const calls = parts.flatMap((p) =>
    "functionCall" in p
      ? [{ name: p.functionCall.name, args: p.functionCall.args, thoughtSignature: p.thoughtSignature }]
      : [],
  );

  if (calls.length === 0) {
    const text = parts.flatMap((p) => ("text" in p ? [p.text] : [])).join("");
    return { $constructor: "discord_bot.step_final", text } as RawValue;
  }
  // The model wants tools: report the whole batch — each call names its tool by
  // index into the tools array + the args it produced; Katari validates each and
  // dispatches them in parallel via call_agent.
  return {
    $constructor: "discord_bot.step_call",
    calls: calls.map((call) => ({
      $constructor: "discord_bot.tool_call",
      tool_index: indexByName.get(call.name) ?? 0,
      name: call.name,
      thought_signature: call.thoughtSignature ?? "",
      args: (call.args ?? {}) as RawValue,
    })),
  } as RawValue;
});
