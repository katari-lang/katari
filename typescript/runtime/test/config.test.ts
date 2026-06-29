// The `KATARI_SECRET_KEY` boot contract: the runtime refuses to start without a valid 32-byte key, so a
// missing / malformed key can never silently leave secrets unencrypted at rest.

import { describe, expect, test } from "vitest";
import { loadEnv } from "../src/config/env.js";

const validKey = Buffer.alloc(32, 7).toString("base64");

describe("KATARI_SECRET_KEY", () => {
  test("a missing key fails validation (boot would reject)", () => {
    expect(() => loadEnv({})).toThrow(/KATARI_SECRET_KEY/);
  });

  test("a non-32-byte key is rejected", () => {
    const tooShort = Buffer.alloc(16, 7).toString("base64");
    expect(() => loadEnv({ KATARI_SECRET_KEY: tooShort })).toThrow(/KATARI_SECRET_KEY/);
  });

  test("a malformed base64 key is rejected", () => {
    expect(() => loadEnv({ KATARI_SECRET_KEY: "not valid base64 !!!" })).toThrow(/KATARI_SECRET_KEY/);
  });

  test("a base64 32-byte key is accepted", () => {
    expect(loadEnv({ KATARI_SECRET_KEY: validKey }).KATARI_SECRET_KEY).toBe(validKey);
  });
});
