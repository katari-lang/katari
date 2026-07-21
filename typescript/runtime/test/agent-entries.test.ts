// Unit tests for the agent-schema reader's pure heart: collecting callable schemas from module IR
// (`collectEntries`) and deriving an escalation's answer schema from a request entry
// (`deriveAnswerSchema`). The DB-facing loader around them needs Postgres; these mappings are pure.

import {
  createAgentName,
  type IRModule,
  type JSONSchema,
  type RequestSchema,
  type SchemaInfo,
} from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { collectEntries, deriveAnswerSchema } from "../src/modules/agent/agent.reader.js";
import { requestsToJson } from "../src/runtime/value/schema-json.js";

function schemaOf(input: object, output: object, requests: RequestSchema[] = []): SchemaInfo {
  return { input, output, requests, genericBindings: {} };
}

/** A minimal one-entry module: `entries[name] -> agent block` carrying the given schema (public by
 *  default; `private` marks the entry handle-private). */
function moduleWithAgent(name: string, schema: SchemaInfo, isPrivate = false): IRModule {
  return {
    metadata: { schemaVersion: 1 },
    blocks: {
      0: { block: { kind: "agent", body: 1, schema, defaults: {} }, parameters: {} },
      1: { block: { kind: "sequence", result: null, operations: [] }, parameters: {} },
    },
    entries: { [createAgentName(name)]: { block: 0, private: isPrivate } },
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
    expect(entries.get("main.main")?.block.schema.input).toEqual(mainSchema.input);
    expect(entries.get("main.ask")?.block.schema.output).toEqual(askSchema.output);
  });

  test("carries each entry's handle privacy (so a listing surface can hide a private agent)", () => {
    const modules = new Map<string, IRModule>([
      ["main", moduleWithAgent("main.shown", mainSchema)],
      ["main.hidden", moduleWithAgent("main.hidden", askSchema, true)],
    ]);
    const entries = collectEntries(modules);
    expect(entries.get("main.shown")?.private).toBe(false);
    expect(entries.get("main.hidden")?.private).toBe(true);
  });

  test("skips an entry whose block is missing or not an agent (defensive against malformed IR)", () => {
    const malformed: IRModule = {
      metadata: { schemaVersion: 1 },
      blocks: {
        0: { block: { kind: "sequence", result: null, operations: [] }, parameters: {} },
      },
      entries: { [createAgentName("main.notAgent")]: { block: 0, private: false }, [createAgentName("main.dangling")]: { block: 9, private: false } },
      names: {},
    };
    const entries = collectEntries(new Map([["main", malformed]]));
    expect(entries.size).toBe(0);
  });
});

describe("agent detail requests", () => {
  // The detail endpoint serves `requestsToJson(entry.block.schema.requests)` — the same
  // `RequestSchema[] -> Json` derivation `reflection.get_metadata` uses. Pin the shape that reaches the
  // console: one `{name, input, output}` per concrete request, a `{$generic}` placeholder otherwise.
  const askInput: JSONSchema = { type: "object", properties: { question: { type: "string" } } };
  const askOutput: JSONSchema = { type: "object", properties: { approved: { type: "boolean" } } };
  const requests: RequestSchema[] = [
    {
      kind: "concrete",
      descriptor: { name: createAgentName("main.ask"), input: askInput, output: askOutput },
    },
    { kind: "generic", generic: 7 },
  ];

  test("derives one {name, input, output} per concrete request, a placeholder for an effect generic", () => {
    const module = moduleWithAgent("main.main", schemaOf(mainSchema.input, mainSchema.output, requests));
    const entry = collectEntries(new Map([["main", module]])).get("main.main");
    expect(entry).toBeDefined();
    expect(requestsToJson(entry?.block.schema.requests ?? [])).toEqual([
      { name: "main.ask", input: askInput, output: askOutput },
      { $generic: 7 },
    ]);
  });

  test("an agent that performs no request derives an empty list (the card is then hidden)", () => {
    const entry = collectEntries(
      new Map([["main", moduleWithAgent("main.main", mainSchema)]]),
    ).get("main.main");
    expect(requestsToJson(entry?.block.schema.requests ?? [])).toEqual([]);
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
