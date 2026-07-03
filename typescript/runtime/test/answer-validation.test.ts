// Unit test for the answer acceptance check — the user-facing half of escalation answering. The answer
// surface is the only *unchecked* entry for answers (a handler's resume value is statically typed), and
// its enforcement is a retryable 400 with the escalation left open, never a panic. (The row lookup and
// schema resolution around it need Postgres; this validates the pure decision.)

import type { JSONSchema } from "@katari-lang/types";
import { describe, expect, test } from "vitest";
import { BadRequestError } from "../src/lib/errors.js";
import { validateAnswer } from "../src/modules/escalation/escalation.service.js";

describe("validateAnswer", () => {
  test("a conforming answer passes", () => {
    expect(() => validateAnswer("Yukiko", { type: "string" })).not.toThrow();
    expect(() => validateAnswer(42, { type: "integer" })).not.toThrow();
  });

  test("an integer answers a number request (subtyping holds at the boundary)", () => {
    expect(() => validateAnswer(1, { type: "number" })).not.toThrow();
  });

  test("a mismatched answer is a 400 whose message names the path and expectation", () => {
    let caught: unknown;
    try {
      validateAnswer("not a number", { type: "integer" });
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeInstanceOf(BadRequestError);
    expect((caught as BadRequestError).message).toContain("$");
    expect((caught as BadRequestError).message).toContain("integer");
  });

  test("a record answer is checked field-by-field", () => {
    const schema: JSONSchema = {
      type: "object",
      properties: { name: { type: "string" }, age: { type: "integer" } },
      required: ["name", "age"],
    };
    expect(() => validateAnswer({ name: "Yukiko", age: 17 }, schema)).not.toThrow();
    expect(() => validateAnswer({ name: "Yukiko", age: "17" }, schema)).toThrow(BadRequestError);
    expect(() => validateAnswer({ name: "Yukiko" }, schema)).toThrow(BadRequestError);
  });

  test("a null schema (none advertised) accepts anything — matching the client's fallback", () => {
    expect(() => validateAnswer({ anything: ["goes", 1, null] }, null)).not.toThrow();
  });
});
