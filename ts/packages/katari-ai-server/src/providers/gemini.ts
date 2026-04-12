import {
  GoogleGenerativeAI,
  type Content,
  type FunctionDeclaration,
  SchemaType,
} from "@google/generative-ai";
import type { JsonValue } from "katari-protocol";
import type { AIProvider, AIResponse, ChatMessage, ToolDef } from "./types.js";

export class GeminiProvider implements AIProvider {
  private genAI: GoogleGenerativeAI;
  private modelName: string;

  constructor(apiKey: string, modelName = "gemini-2.0-flash") {
    this.genAI = new GoogleGenerativeAI(apiKey);
    this.modelName = modelName;
  }

  async chat(messages: ChatMessage[], tools?: ToolDef[]): Promise<AIResponse> {
    const functionDeclarations: FunctionDeclaration[] = (tools ?? []).map(
      (t) =>
        ({
          name: t.name,
          description: t.description,
          parameters: {
            type: SchemaType.OBJECT,
            properties: Object.fromEntries(
              Object.entries(t.parameters).map(([k, v]) => [
                k,
                {
                  type: mapType(v.type),
                  description: v.description,
                },
              ])
            ),
            required: Object.keys(t.parameters),
          },
        }) as FunctionDeclaration
    );

    const model = this.genAI.getGenerativeModel({
      model: this.modelName,
      ...(functionDeclarations.length > 0
        ? { tools: [{ functionDeclarations }] }
        : {}),
    });

    // Build contents from messages
    const systemInstruction = messages.find((m) => m.role === "system")?.content;
    const contents = messagesToContents(
      messages.filter((m) => m.role !== "system")
    );

    const result = await model.generateContent({
      contents,
      ...(systemInstruction ? { systemInstruction } : {}),
    });

    const response = result.response;
    const candidate = response.candidates?.[0];
    if (!candidate) {
      return { content: "", toolCalls: [] };
    }

    const toolCalls = candidate.content.parts
      .filter((p) => p.functionCall)
      .map((p, i) => ({
        id: `call_${i}`,
        name: p.functionCall!.name,
        arguments: (p.functionCall!.args ?? {}) as Record<string, JsonValue>,
      }));

    const textParts = candidate.content.parts.filter((p) => p.text);
    const content = textParts.map((p) => p.text).join("") || null;

    return { content, toolCalls };
  }
}

function messagesToContents(messages: ChatMessage[]): Content[] {
  return messages.map((m) => {
    if (m.role === "tool" && m.toolCallId) {
      return {
        role: "function",
        parts: [
          {
            functionResponse: {
              name: m.toolCallId,
              response: { result: m.content },
            },
          },
        ],
      };
    }

    if (m.toolCalls && m.toolCalls.length > 0) {
      return {
        role: "model",
        parts: m.toolCalls.map((tc) => ({
          functionCall: { name: tc.name, args: tc.arguments },
        })),
      };
    }

    return {
      role: m.role === "model" ? "model" : "user",
      parts: [{ text: m.content }],
    };
  });
}

function mapType(t: string): SchemaType {
  switch (t) {
    case "integer":
    case "number":
      return SchemaType.NUMBER;
    case "boolean":
      return SchemaType.BOOLEAN;
    case "array":
      return SchemaType.ARRAY;
    case "object":
      return SchemaType.OBJECT;
    default:
      return SchemaType.STRING;
  }
}
