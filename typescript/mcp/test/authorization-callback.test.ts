// Unit tests for the authorization-callback parsing — the non-interactive seam of the OAuth flow
// that `list-tools --oauth` runs (code / state / IdP-refusal handling on the loopback redirect).
// The full flow needs a browser and an IdP, so it is exercised by hand — see `performLogin`'s doc
// comment in src/index.ts.

import { describe, expect, test } from "vitest";
import { parseAuthorizationCallback } from "../src/index.js";

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
