// TypeScript mirror of Katari.Schema.SchemaBundle (Haskell).
//
// SchemaBundle is the AI tool-calling–oriented JSON Schema artifact produced
// alongside IRModule by katari-compiler. The runtime treats the inner JSON
// schemas as opaque — they are stored, served via `GET /agent-definition`,
// and forwarded to AI clients without inspection. Only the outer structure
// (qualifiedName / parameters / returns / description) is shaped here.
//
// If the Haskell SchemaBundle layout changes, update this file to match.

import type { QualifiedName } from "./types.js";

/** A JSON Schema document (RFC draft-07-ish). Treated as opaque JSON. */
export type JsonSchema = unknown;

/** Per-entry agent definition exposed to AI tool callers. */
export type AgentDefinition = {
  qualifiedName: QualifiedName;
  parameters: JsonSchema;
  returns: JsonSchema;
  description?: string;
};

export type SchemaBundle = {
  schemaVersion: number;
  agents: AgentDefinition[];
};
