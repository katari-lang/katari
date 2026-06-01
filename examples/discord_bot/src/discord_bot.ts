// Ext (sidecar) implementation for discord_bot.ktr.
//
// `create_session` allocates an in-sidecar conversation (its message history
// lives here, not in Katari — the language has no list-append yet). `ai_infer`
// runs one turn against the AI provider, keeping the running history.
//
// The api key arrives inside the `ai_client` value as a `secret` field, which
// reaches the sidecar as `{ $secret: "<plaintext>" }` (the sidecar is inside
// the runtime's trust boundary — it's the party that legitimately holds the
// cleartext credential).

import katari, { KatariString } from "@katari-lang/port";

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
  api_key: { $secret: string };
};

katari.agent<{ client: AiClient; session: KatariString; prompt: KatariString }>(
  "ai_infer",
  async ({ args }) => {
    const { client } = args;

    const session = await katari.readString(args.session);
    const prompt = await katari.readString(args.prompt);

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
      .map((p) => p.text ?? "")
      .join("");

    history.push({ role: "model", parts: [{ text: reply }] });
    sessions.set(session, history);
    return reply;
  },
);
