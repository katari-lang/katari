// Unit tests for the login flow's non-interactive seams: argument parsing (what exit-2 usage errors
// guard) and the authorization-callback parsing (code / state / IdP-refusal handling). The full flow
// needs a browser and an IdP, so it is exercised by hand — see `performLogin`'s doc comment.

import { describe, expect, test } from "vitest";
import { parseAuthorizationCallback, parseLoginArguments } from "../src/index.js";

describe("parseLoginArguments", () => {
  test("parses --url alone", () => {
    expect(parseLoginArguments(["--url", "https://mcp.example.test/mcp"])).toEqual({
      url: "https://mcp.example.test/mcp",
    });
  });

  test("parses --url with --scope", () => {
    expect(
      parseLoginArguments(["--url", "https://mcp.example.test/mcp", "--scope", "repo read:user"]),
    ).toEqual({ url: "https://mcp.example.test/mcp", scope: "repo read:user" });
  });

  test("rejects a missing --url", () => {
    expect(() => parseLoginArguments([])).toThrowError(/--url/);
    expect(() => parseLoginArguments(["--scope", "repo"])).toThrowError(/--url/);
  });

  test("rejects an unknown flag and a flag with no value", () => {
    expect(() => parseLoginArguments(["--nope", "x"])).toThrowError(/unknown argument/);
    expect(() => parseLoginArguments(["--url"])).toThrowError(/requires a value/);
  });
});

describe("parseAuthorizationCallback", () => {
  test("accepts a code whose state matches", () => {
    expect(parseAuthorizationCallback("/callback?code=abc&state=s1", "s1")).toEqual({
      kind: "code",
      code: "abc",
    });
  });

  test("rejects a mismatched state (the reply is not for this flow's request)", () => {
    const outcome = parseAuthorizationCallback("/callback?code=abc&state=other", "s1");
    expect(outcome.kind).toBe("rejected");
  });

  test("rejects a redirect with no code", () => {
    const outcome = parseAuthorizationCallback("/callback?state=s1", "s1");
    expect(outcome.kind).toBe("rejected");
  });

  test("surfaces the IdP's refusal with its description", () => {
    const outcome = parseAuthorizationCallback(
      "/callback?error=access_denied&error_description=user%20said%20no",
      "s1",
    );
    if (outcome.kind !== "rejected") throw new Error("expected a rejection");
    expect(outcome.message).toBe("access_denied: user said no");
  });
});
