// Unit test for the user-facing escalation filter — shared by the actor's recovery rehydration and the
// API's open-escalation list, so both present the same set. (The list query itself joins escalations →
// instances → delegations and needs Postgres; this filter is the pure part.)

import { describe, expect, test } from "vitest";
import { PANIC_REQUEST } from "../src/runtime/engine/common.js";
import { isUserFacingRequest } from "../src/runtime/escalation-filter.js";

describe("isUserFacingRequest", () => {
  test("a genuine (qualified) capability request is user-facing", () => {
    expect(isUserFacingRequest("demo.ask_value")).toBe(true);
    expect(isUserFacingRequest("ask_human")).toBe(true);
  });

  test("a panic is not user-facing (it fails the run)", () => {
    expect(isUserFacingRequest(PANIC_REQUEST)).toBe(false);
  });

  test("control-flow escapes crossing a boundary are not user-facing", () => {
    for (const kind of ["next", "next-for", "return", "break", "break-for"]) {
      expect(isUserFacingRequest(kind)).toBe(false);
    }
  });
});
