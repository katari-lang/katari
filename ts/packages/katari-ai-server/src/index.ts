import { startServer } from "katari-protocol";
import type { AgentHandlerFn, AgentContext, JsonValue } from "katari-protocol";
import { GeminiProvider } from "./providers/gemini.js";
import type { AIProvider, ChatMessage, ToolDef, ToolCall } from "./providers/types.js";

// ===========================================================================
// AgentRef — resolved reference from prim.ref_agent
// ===========================================================================

interface AgentRef {
  url: string;
  agent_def_id: string;
  name: string;
  description: string;
  arg_type: JsonValue;
}

// ===========================================================================
// AI Provider
// ===========================================================================

function createProvider(): AIProvider {
  const provider = process.env.AI_PROVIDER ?? "gemini";
  switch (provider) {
    case "gemini": {
      const apiKey = process.env.GEMINI_API_KEY;
      if (!apiKey) {
        console.error("GEMINI_API_KEY is required");
        process.exit(1);
      }
      return new GeminiProvider(apiKey);
    }
    default:
      console.error(`Unknown AI_PROVIDER: ${provider}`);
      process.exit(1);
  }
}

const ai = createProvider();

// ===========================================================================
// Tool definition builder from AgentRef
// ===========================================================================

function buildToolDefFromRef(ref: AgentRef): ToolDef {
  const argType = ref.arg_type as Record<string, JsonValue> | null;
  const properties = (argType?.properties ?? {}) as Record<
    string,
    Record<string, JsonValue>
  >;
  return {
    name: ref.name,
    description: ref.description,
    parameters: Object.fromEntries(
      Object.entries(properties).map(([k, v]) => [
        k,
        {
          type: (v.type as string) ?? "string",
          description: (v.description as string) ?? k,
        },
      ])
    ),
  };
}

// ===========================================================================
// Session management
// ===========================================================================

interface ChatSession {
  messages: ChatMessage[];
}

const sessions = new Map<string, ChatSession>();

// ===========================================================================
// Handlers
// ===========================================================================

const createSession: AgentHandlerFn = async () => {
  const sessionId = crypto.randomUUID();
  sessions.set(sessionId, { messages: [] });
  return sessionId as JsonValue;
};

const askWithTools: AgentHandlerFn = async (args, ctx) => {
  const a = args as Record<string, JsonValue>;
  const sessionId = a.session_id as string;
  const system = a.system as string;
  const prompt = a.prompt as string;
  const agentRefs = a.tools as unknown as AgentRef[];

  let session = sessions.get(sessionId);
  if (!session) {
    session = { messages: [] };
    sessions.set(sessionId, session);
  }

  const tools = agentRefs.map(buildToolDefFromRef);

  // Add user message
  session.messages.push({ role: "user", content: prompt });

  // Build messages with system prompt
  const allMessages: ChatMessage[] = [
    { role: "system", content: system },
    ...session.messages,
  ];

  // Conversation loop (handle tool calls)
  const MAX_ROUNDS = 10;
  for (let round = 0; round < MAX_ROUNDS; round++) {
    const response = await ai.chat(allMessages, tools);

    if (response.toolCalls.length === 0) {
      // Final text response
      const text = response.content ?? "";
      session.messages.push({ role: "model", content: text });
      return text as JsonValue;
    }

    // Record model's tool call in history
    const modelMsg: ChatMessage = {
      role: "model",
      content: "",
      toolCalls: response.toolCalls,
      _rawModelParts: response._rawModelParts,
    };
    session.messages.push(modelMsg);
    allMessages.push(modelMsg);

    // Execute each tool call
    for (const tc of response.toolCalls) {
      const result = await executeToolCall(tc, ctx, agentRefs);
      const toolMsg: ChatMessage = {
        role: "tool",
        content: typeof result === "string" ? result : JSON.stringify(result),
        toolCallId: tc.name,
      };
      session.messages.push(toolMsg);
      allMessages.push(toolMsg);
    }
  }

  // Exceeded max rounds
  const fallback = "Tool call limit reached.";
  session.messages.push({ role: "model", content: fallback });
  return fallback as JsonValue;
};

async function executeToolCall(
  tc: ToolCall,
  ctx: AgentContext,
  refs: AgentRef[]
): Promise<JsonValue> {
  const ref = refs.find((r) => r.name === tc.name);
  if (!ref) {
    return `Unknown tool: ${tc.name}`;
  }

  try {
    return await ctx.delegateAndWait(
      ref.url,
      ref.agent_def_id,
      tc.arguments as Record<string, JsonValue>
    );
  } catch (e) {
    return `Tool execution failed: ${e}`;
  }
}

// ===========================================================================
// Start
// ===========================================================================

const port = parseInt(process.env.PORT ?? "8002", 10);
const endpoint = process.env.KATARI_BASE_URL ?? `http://localhost:${port}`;
const databaseUrl = process.env.DATABASE_URL;

startServer({
  port,
  endpoint,
  databaseUrl,
  agentDefs: {
    create_session: { handler: createSession, description: "Create a new AI chat session" },
    ask_with_tools: { handler: askWithTools, description: "Send a prompt with tool-use to the AI" },
  },
});
