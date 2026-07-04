// The boot key contract: the runtime refuses to start without a valid at-rest key (KATARI_SECRET_KEY) AND
// an API bearer token (KATARI_API_KEY), so neither secrets-unencrypted-at-rest nor an-open-API can happen
// by omission.

import { describe, expect, test } from "vitest";
import { loadEnv } from "../src/config/env.js";

const validKey = Buffer.alloc(32, 7).toString("base64");
const withApiKey = { KATARI_API_KEY: "a-token" };

describe("KATARI_SECRET_KEY", () => {
  test("a missing key fails validation (boot would reject)", () => {
    expect(() => loadEnv(withApiKey)).toThrow(/KATARI_SECRET_KEY/);
  });

  test("a non-32-byte key is rejected", () => {
    const tooShort = Buffer.alloc(16, 7).toString("base64");
    expect(() => loadEnv({ ...withApiKey, KATARI_SECRET_KEY: tooShort })).toThrow(/KATARI_SECRET_KEY/);
  });

  test("a malformed base64 key is rejected", () => {
    expect(() => loadEnv({ ...withApiKey, KATARI_SECRET_KEY: "not valid base64 !!!" })).toThrow(
      /KATARI_SECRET_KEY/,
    );
  });

  test("a base64 32-byte key is accepted", () => {
    expect(loadEnv({ ...withApiKey, KATARI_SECRET_KEY: validKey }).KATARI_SECRET_KEY).toBe(validKey);
  });
});

describe("KATARI_API_KEY", () => {
  test("a missing API key fails validation (boot would reject — the API is never left open)", () => {
    expect(() => loadEnv({ KATARI_SECRET_KEY: validKey })).toThrow(/KATARI_API_KEY/);
  });

  test("an empty API key is rejected", () => {
    expect(() => loadEnv({ KATARI_SECRET_KEY: validKey, KATARI_API_KEY: "" })).toThrow(
      /KATARI_API_KEY/,
    );
  });

  test("a non-empty API key is accepted", () => {
    expect(loadEnv({ KATARI_SECRET_KEY: validKey, KATARI_API_KEY: "tok" }).KATARI_API_KEY).toBe("tok");
  });
});
