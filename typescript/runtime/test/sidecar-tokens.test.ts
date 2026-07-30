// The sidecar capability token. A sidecar runs the user's own FFI handlers — and, on a project with
// third-party dependencies, someone else's JavaScript — so what it holds must open the two blob paths of its
// own project and nothing else. These tests pin that boundary, because the failure mode of getting it wrong
// is silent: a token that works too widely still works.

import { describe, expect, test } from "vitest";
import {
  liveSidecarTokenCount,
  mintSidecarToken,
  revokeSidecarToken,
  sidecarTokenAuthorizes,
} from "../src/lib/sidecar-tokens.js";
import type { ProjectId } from "../src/runtime/ids.js";

const PROJECT = "11111111-1111-1111-1111-111111111111" as ProjectId;
const OTHER_PROJECT = "22222222-2222-2222-2222-222222222222" as ProjectId;

describe("mintSidecarToken", () => {
  test("mints an unguessable token", () => {
    const token = mintSidecarToken(PROJECT);
    revokeSidecarToken(token);
    // 24 CSPRNG bytes as base64url — the length is the visible proxy for the entropy behind it.
    expect(token).toMatch(/^[A-Za-z0-9_-]{32}$/);
  });

  test("mints a distinct token each time", () => {
    const first = mintSidecarToken(PROJECT);
    const second = mintSidecarToken(PROJECT);
    expect(first).not.toBe(second);
    revokeSidecarToken(first);
    revokeSidecarToken(second);
  });
});

describe("sidecarTokenAuthorizes", () => {
  test("allows its own project's blob download and upload", () => {
    const token = mintSidecarToken(PROJECT);
    try {
      expect(sidecarTokenAuthorizes(token, "GET", `/api/v1/projects/${PROJECT}/files/blob-1`)).toBe(
        true,
      );
      expect(
        sidecarTokenAuthorizes(token, "POST", `/api/v1/projects/${PROJECT}/ffi/deleg-1/blobs`),
      ).toBe(true);
    } finally {
      revokeSidecarToken(token);
    }
  });

  test("refuses another project's blobs", () => {
    const token = mintSidecarToken(PROJECT);
    try {
      expect(
        sidecarTokenAuthorizes(token, "GET", `/api/v1/projects/${OTHER_PROJECT}/files/blob-1`),
      ).toBe(false);
    } finally {
      revokeSidecarToken(token);
    }
  });

  // The whole point of the change: the credential a sidecar holds must not be able to act as the operator.
  test.each([
    ["GET", "/api/v1/projects"],
    ["POST", "/api/v1/projects"],
    ["GET", `/api/v1/projects/${PROJECT}/env`],
    ["POST", `/api/v1/projects/${PROJECT}/env`],
    ["POST", `/api/v1/projects/${PROJECT}/snapshots`],
    ["POST", `/api/v1/projects/${PROJECT}/runs`],
    ["GET", `/api/v1/projects/${PROJECT}/store/anything`],
    ["DELETE", `/api/v1/projects/${PROJECT}`],
  ])("refuses %s %s", (method, path) => {
    const token = mintSidecarToken(PROJECT);
    try {
      expect(sidecarTokenAuthorizes(token, method, path)).toBe(false);
    } finally {
      revokeSidecarToken(token);
    }
  });

  test("refuses a write on the read path (the method is part of the grant)", () => {
    const token = mintSidecarToken(PROJECT);
    try {
      expect(
        sidecarTokenAuthorizes(token, "DELETE", `/api/v1/projects/${PROJECT}/files/blob-1`),
      ).toBe(false);
    } finally {
      revokeSidecarToken(token);
    }
  });

  test("refuses a path that only looks like the blob route", () => {
    const token = mintSidecarToken(PROJECT);
    try {
      // A deeper path must not match: the patterns are anchored so a new route under `files/` cannot be
      // reached by a token that was only meant to read one blob.
      expect(
        sidecarTokenAuthorizes(token, "GET", `/api/v1/projects/${PROJECT}/files/blob-1/secrets`),
      ).toBe(false);
    } finally {
      revokeSidecarToken(token);
    }
  });

  test("refuses an unknown token", () => {
    expect(
      sidecarTokenAuthorizes("not-a-real-token", "GET", `/api/v1/projects/${PROJECT}/files/b`),
    ).toBe(false);
  });

  test("refuses a revoked token — the capability dies with its process", () => {
    const token = mintSidecarToken(PROJECT);
    const path = `/api/v1/projects/${PROJECT}/files/blob-1`;
    expect(sidecarTokenAuthorizes(token, "GET", path)).toBe(true);
    revokeSidecarToken(token);
    expect(sidecarTokenAuthorizes(token, "GET", path)).toBe(false);
  });
});

describe("revokeSidecarToken", () => {
  test("leaves nothing behind, so a long-lived runtime does not accumulate grants", () => {
    const before = liveSidecarTokenCount();
    const tokens = [mintSidecarToken(PROJECT), mintSidecarToken(OTHER_PROJECT)];
    expect(liveSidecarTokenCount()).toBe(before + 2);
    for (const token of tokens) revokeSidecarToken(token);
    expect(liveSidecarTokenCount()).toBe(before);
  });

  test("is idempotent (both teardown paths may fire)", () => {
    const token = mintSidecarToken(PROJECT);
    revokeSidecarToken(token);
    expect(() => revokeSidecarToken(token)).not.toThrow();
  });
});
