// The boot key contract: the runtime refuses to start without a valid at-rest key (KATARI_SECRET_KEY) AND
// an API bearer token (KATARI_API_KEY), so neither secrets-unencrypted-at-rest nor an-open-API can happen
// by omission. The API key additionally has an ENTROPY floor rather than a mere non-empty check, because it
// is the whole of the API's authentication and nothing rate-limits guesses at network speed.

import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { loadEnv } from "../src/config/env.js";

const validKey = Buffer.alloc(32, 7).toString("base64");
const validApiKey = "a-token-that-is-long-enough-0000000";
const withApiKey = { KATARI_API_KEY: validApiKey };

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

  test("a previous-key list is accepted so a rotation can still decrypt old values", () => {
    const previous = Buffer.alloc(32, 9).toString("base64");
    const loaded = loadEnv({
      ...withApiKey,
      KATARI_SECRET_KEY: validKey,
      KATARI_SECRET_KEY_PREVIOUS: previous,
    });
    expect(loaded.KATARI_SECRET_KEY_PREVIOUS).toBe(previous);
  });

  test("a malformed previous key is rejected rather than silently ignored", () => {
    expect(() =>
      loadEnv({
        ...withApiKey,
        KATARI_SECRET_KEY: validKey,
        KATARI_SECRET_KEY_PREVIOUS: "nonsense",
      }),
    ).toThrow(/KATARI_SECRET_KEY_PREVIOUS/);
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

  test("a short API key is rejected — guessability is the threat, not emptiness", () => {
    expect(() => loadEnv({ KATARI_SECRET_KEY: validKey, KATARI_API_KEY: "tok" })).toThrow(
      /KATARI_API_KEY/,
    );
  });

  test("an API key at the length floor is accepted", () => {
    expect(
      loadEnv({ KATARI_SECRET_KEY: validKey, KATARI_API_KEY: validApiKey }).KATARI_API_KEY,
    ).toBe(validApiKey);
  });
});

describe("file-backed variables", () => {
  const directory = mkdtempSync(join(tmpdir(), "katari-config-test-"));

  test("a value can arrive from a file instead of the environment", () => {
    const path = join(directory, "api-key");
    // The trailing newline is deliberate: a mounted secret usually has one, and it must not become part of
    // the key.
    writeFileSync(path, `${validApiKey}\n`);
    const loaded = loadEnv({ KATARI_SECRET_KEY: validKey, KATARI_API_KEY_FILE: path });
    expect(loaded.KATARI_API_KEY).toBe(validApiKey);
  });

  test("setting both the variable and its _FILE form is an error rather than a silent precedence rule", () => {
    const path = join(directory, "api-key-conflict");
    writeFileSync(path, validApiKey);
    expect(() =>
      loadEnv({
        KATARI_SECRET_KEY: validKey,
        KATARI_API_KEY: validApiKey,
        KATARI_API_KEY_FILE: path,
      }),
    ).toThrow(/not both/);
  });

  test("an unreadable _FILE path names the variable it was for", () => {
    expect(() =>
      loadEnv({
        KATARI_SECRET_KEY: validKey,
        KATARI_API_KEY_FILE: join(directory, "does-not-exist"),
      }),
    ).toThrow(/KATARI_API_KEY_FILE/);
  });
});

describe("KATARI_PUBLIC_URL", () => {
  test("production refuses to boot without the address external services reach it at", () => {
    expect(() =>
      loadEnv({ ...withApiKey, KATARI_SECRET_KEY: validKey, NODE_ENV: "production" }),
    ).toThrow(/KATARI_PUBLIC_URL/);
  });

  test("development is happy without it (the local default is reachable there)", () => {
    expect(
      loadEnv({ ...withApiKey, KATARI_SECRET_KEY: validKey, NODE_ENV: "development" }).NODE_ENV,
    ).toBe("development");
  });
});
