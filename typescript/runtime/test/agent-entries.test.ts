// Unit tests for the agent-schema reader's pure heart: collecting callable schemas from module IR
// (`collectEntries`) and deriving an escalation's answer schema from a request entry
// (`deriveAnswerSchema`). The DB-facing loader around them needs Postgres; these mappings are pure.

import { createAgentName, type IRModule, type SchemaInfo } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { collectEntries, deriveAnswerSchema } from "../src/modules/agent/agent.reader.js";

function schemaOf(input: object, output: object): SchemaInfo {
  return { input, output, requests: [], genericBindings: {} };
}

/** A minimal one-entry module: `entries[name] -> agent block` carrying the given schema. */
function moduleWithAgent(name: string, schema: SchemaInfo): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema, defaults: {} }, parameters: {} },
      1: { block: { kind: "sequence", result: null, operations: [] }, parameters: {} },
    },
    entries: { [createAgentName(name)]: 0 },
    names: {},
  };
}

const mainSchema = schemaOf(
  { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
  { type: "string" },
);
const askSchema = schemaOf(
  { type: "object", properties: { question: { type: "string" } } },
  { type: "object", properties: { approved: { type: "boolean" } }, required: ["approved"] },
);

describe("collectEntries", () => {
  test("collects every entry's schema across modules, keyed by qualified name", () => {
    const modules = new Map<string, IRModule>([
      ["main", moduleWithAgent("main.main", mainSchema)],
      ["main.ask", moduleWithAgent("main.ask", askSchema)],
    ]);
    const entries = collectEntries(modules);
    expect(entries.size).toBe(2);
    expect(entries.get("main.main")?.input).toEqual(mainSchema.input);
    expect(entries.get("main.ask")?.output).toEqual(askSchema.output);
  });

  test("skips an entry whose block is missing or not an agent (defensive against malformed IR)", () => {
    const malformed: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "sequence", result: null, operations: [] }, parameters: {} },
      },
      entries: { [createAgentName("main.notAgent")]: 0, [createAgentName("main.dangling")]: 9 },
      names: {},
    };
    const entries = collectEntries(new Map([["main", malformed]]));
    expect(entries.size).toBe(0);
  });
});

describe("deriveAnswerSchema", () => {
  test("the answer schema is the request entry's output schema", () => {
    const entries = collectEntries(new Map([["main", moduleWithAgent("main.ask", askSchema)]]));
    expect(deriveAnswerSchema(entries, "main.ask")).toEqual(askSchema.output);
  });

  test("an unknown request derives null (the client falls back to unvalidated input)", () => {
    const entries = collectEntries(new Map([["main", moduleWithAgent("main.ask", askSchema)]]));
    expect(deriveAnswerSchema(entries, "main.vanished")).toBeNull();
  });
});
