import { startServer } from "katari-protocol";
import type { AgentHandlerFn, AgentContext, JsonValue } from "katari-protocol";
import type { AgentDefInfo } from "katari-protocol";
import { GeminiProvider } from "./providers/gemini.js";
import type { AIProvider, ChatMessage, ToolDef, ToolCall } from "./providers/types.js";

// ===========================================================================
// Configuration
// ===========================================================================

const RUNTIME_KATARI_URL = process.env.RUNTIME_KATARI_URL ?? "http://localhost:8000/katari";

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
// Tool definition cache (fetched from runtime)
// ===========================================================================

interface CachedToolDef {
  agentDefId: string;
  name: string;
  description: string;
  argType: JsonValue; // JSON Schema object
  paramOrder: string[]; // ordered param names from "required"
}

let cachedTools: CachedToolDef[] = [];
let toolsFetched = false;

async function fetchToolDefs(): Promise<void> {
  try {
    const resp = await fetch(`${RUNTIME_KATARI_URL}/agent_def`);
    if (!resp.ok) {
      console.error(`Failed to fetch agent_defs: ${resp.status}`);
      return;
    }
    const defs = (await resp.json()) as AgentDefInfo[];
    cachedTools = defs.map((d) => {
      const argType = d.arg_type as Record<string, JsonValue> | null;
      const paramOrder = (argType?.required as string[]) ?? [];
      return {
        agentDefId: d.agent_def_id,
        name: d.name,
        description: d.description ?? "",
        argType: d.arg_type,
        paramOrder,
      };
    });
    toolsFetched = true;
    console.log(`Fetched ${cachedTools.length} tool definitions from runtime`);
  } catch (e) {
    console.error(`Failed to fetch tool defs:`, e);
  }
}

function buildToolDefs(toolNames: string[]): ToolDef[] {
  return toolNames
    .map((name) => {
      const cached = cachedTools.find((t) => t.name === name);
      if (!cached) return null;
      const argType = cached.argType as Record<string, JsonValue> | null;
      const properties = (argType?.properties ?? {}) as Record<
        string,
        Record<string, JsonValue>
      >;
      return {
        name: cached.name,
        description: cached.description,
        parameters: Object.fromEntries(
          Object.entries(properties).map(([k, v]) => [
            k,
            {
              type: (v.type as string) ?? "string",
              description: (v.description as string) ?? k,
            },
          ])
        ),
      } satisfies ToolDef;
    })
    .filter((t): t is ToolDef => t !== null);
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
  const sessionId = args[0] as string;
  const system = args[1] as string;
  const prompt = args[2] as string;
  const toolNames = args[3] as string[];

  // Fetch tool defs if not yet cached
  if (!toolsFetched) {
    await fetchToolDefs();
  }

  let session = sessions.get(sessionId);
  if (!session) {
    session = { messages: [] };
    sessions.set(sessionId, session);
  }

  const tools = buildToolDefs(toolNames);

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
  const cached = cachedTools.find((t) => t.name === tc.name);
  if (!cached) {
    return `Unknown tool: ${tc.name}`;
  }

  // Build args array in the parameter order from schema
  const args: JsonValue[] = cached.paramOrder.map(
    (p) => (tc.arguments[p] as JsonValue) ?? null
  );

  try {
    const result = await ctx.spawnAndWait(
      RUNTIME_KATARI_URL,
      cached.agentDefId,
      args
    );
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
  process.env.KATARI_BASE_URL ?? `http://localhost:${port}/katari`;

startServer({
  port,
  selfBaseUrl,
  handlers: {
    create_session: createSession,
    ask_with_tools: askWithTools,
  },
});
