import { startServer } from "katari-protocol";
import type { AgentHandlerFn, AgentContext, JsonValue } from "katari-protocol";
import { GeminiProvider } from "./providers/gemini.js";
import type { AIProvider, ChatMessage, ToolDef, ToolCall } from "./providers/types.js";

// ===========================================================================
// Configuration
// ===========================================================================

interface ToolRoute {
  url: string;
  def: string;
  description: string;
  params: { name: string; type: string; description?: string }[];
}

const toolRoutes: Record<string, ToolRoute> = JSON.parse(
  process.env.TOOL_ROUTES ?? "{}"
);

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
  const sessionId = args[0] as string;
  const system = args[1] as string;
  const prompt = args[2] as string;
  const toolNames = args[3] as string[];

  let session = sessions.get(sessionId);
  if (!session) {
    session = { messages: [] };
    sessions.set(sessionId, session);
  }

  // Build tool definitions from TOOL_ROUTES
  const tools: ToolDef[] = toolNames
    .map((name) => {
      const route = toolRoutes[name];
      if (!route) return null;
      return {
        name,
        description: route.description,
        parameters: Object.fromEntries(
          route.params.map((p) => [
            p.name,
            { type: p.type, description: p.description ?? p.name },
          ])
        ),
      };
    })
    .filter((t): t is ToolDef => t !== null);

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
    session.messages.push({
      role: "model",
      content: "",
      toolCalls: response.toolCalls,
    });
    allMessages.push({
      role: "model",
      content: "",
      toolCalls: response.toolCalls,
    });

    // Execute each tool call
    for (const tc of response.toolCalls) {
      const result = await executeToolCall(tc, ctx);
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
  ctx: AgentContext
): Promise<JsonValue> {
  const route = toolRoutes[tc.name];
  if (!route) {
    return `Unknown tool: ${tc.name}`;
  }

  // Build args array in the order defined by params
  const args: JsonValue[] = route.params.map(
    (p) => (tc.arguments[p.name] as JsonValue) ?? null
  );

  try {
    const result = await ctx.spawnAndWait(route.url, route.def, args);
    return result;
  } catch (e) {
    return `Tool execution failed: ${e}`;
  }
}

// ===========================================================================
// Start
// ===========================================================================

const port = parseInt(process.env.PORT ?? "8002", 10);
const selfBaseUrl =
  process.env.SELF_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: {
    create_session: createSession,
    ask_with_tools: askWithTools,
  },
});
