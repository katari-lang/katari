// Compact read-only rendering of a JSON Schema (Draft 2020-12 canonical shapes, as the compiler
// emits them) in a type-expression-like syntax, far easier to scan than raw schema JSON. The raw
// document stays one copy-click away.

import type { Json, JsonSchema } from "../../api/types";
import { CopyButton } from "../ui/Copy";

export function SchemaViewer({ schema }: { schema: JsonSchema }) {
  return (
    <div className="flex items-start justify-between gap-2">
      <pre className="overflow-x-auto font-mono text-xs leading-relaxed whitespace-pre-wrap">
        {renderSchema(schema, 0)}
      </pre>
      <CopyButton value={JSON.stringify(schema, null, 2)} label="Copy schema JSON" />
    </div>
  );
}

const indentOf = (depth: number) => "  ".repeat(depth);

export function renderSchema(schema: Json, depth: number): string {
  if (typeof schema !== "object" || schema === null || Array.isArray(schema)) {
    return JSON.stringify(schema);
  }
  const node = schema as JsonSchema;

  if (node.$generic !== undefined) return `T${JSON.stringify(node.$generic)}`;
  if (node.const !== undefined) return JSON.stringify(node.const);
  if (Array.isArray(node.enum))
    return node.enum.map((option) => JSON.stringify(option)).join(" | ");
  if (Array.isArray(node.anyOf)) {
    return node.anyOf.map((branch) => renderSchema(branch, depth)).join(" | ");
  }

  const type = node.type;
  if (type === "object" || node.properties !== undefined) return renderObject(node, depth);
  if (type === "array" || node.items !== undefined || node.prefixItems !== undefined) {
    if (Array.isArray(node.prefixItems)) {
      return `[${node.prefixItems.map((item) => renderSchema(item, depth)).join(", ")}]`;
    }
    return `array[${node.items === undefined ? "unknown" : renderSchema(node.items, depth)}]`;
  }
  if (typeof type === "string") return type;
  if (Array.isArray(type)) return type.join(" | ");
  return "unknown";
}

function renderObject(node: JsonSchema, depth: number): string {
  const properties = node.properties;
  if (typeof properties === "object" && properties !== null && !Array.isArray(properties)) {
    const required = new Set(Array.isArray(node.required) ? node.required : []);
    const entries = Object.entries(properties);
    if (entries.length === 0) return "{}";
    const body = entries
      .map(
        ([name, child]) =>
          `${indentOf(depth + 1)}${name}${required.has(name) ? "" : "?"}: ${renderSchema(child, depth + 1)}`,
      )
      .join(",\n");
    return `{\n${body}\n${indentOf(depth)}}`;
  }
  if (node.additionalProperties !== undefined && node.additionalProperties !== true) {
    return `record[${renderSchema(node.additionalProperties, depth)}]`;
  }
  return "record";
}
