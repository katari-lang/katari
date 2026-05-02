import type { JsonValue } from "katari-protocol";

export interface ChatMessage {
  role: "system" | "user" | "model" | "tool";
  content: string;
  toolCallId?: string;
  toolCalls?: ToolCall[];
  /** Provider-specific raw model response parts (e.g. Gemini thought_signature) */
  _rawModelParts?: unknown[];
}

export interface ToolDef {
  name: string;
  description: string;
  parameters: Record<string, ToolParam>;
}

export interface ToolParam {
  type: string;
  description: string;
}

export interface ToolCall {
  id: string;
  name: string;
  arguments: Record<string, JsonValue>;
}

export interface AIResponse {
  content: string | null;
  toolCalls: ToolCall[];
  /** Provider-specific raw model response parts (e.g. Gemini thought_signature) */
  _rawModelParts?: unknown[];
}

export interface AIProvider {
  chat(
    messages: ChatMessage[],
    tools?: ToolDef[]
  ): Promise<AIResponse>;
}
