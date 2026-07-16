// The `credentials` repository's write semantics — the two writers with different intent
// (docs/2026-07-14-credentials-core.md §1): the flow completion's unconditional, generation-bumping
// `upsert` ("a new authorization always wins") and the refresh write-back's `saveWithGeneration`
// compare-and-set (a stale rotation is refused, and never resurrects a deleted credential). The
// generation is opaque to callers, so the tests assert its RULE — every write strictly exceeds every
// generation previously minted for the (project, name), surviving delete + re-creation — not values.
//
// These run against the real Postgres schema (the CAS must be one atomic UPDATE, which no in-memory
// stub can vouch for) and skip when no database is reachable — the suite must stay green on a bare
// CI runner, where the flow/presentation tests still cover the pure logic.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { closeDb, db } from "../src/db/client.js";
import { credentials } from "../src/db/tables/credentials.js";
import { projects } from "../src/db/tables/projects.js";
import { credentialRepository } from "../src/modules/credential/credential.repository.js";

const databaseAvailable = await (async () => {
  try {
    await db.select({ name: credentials.name }).from(credentials).limit(1);
    return true;
  } catch {
    return false;
  }
})();

// The pool must close whether the suite ran or skipped, or the worker lingers on the probe's socket.
afterAll(() => closeDb());

/** Load the row's generation, failing the test when the row is absent. */
async function generationOf(projectId: string, name: string): Promise<number> {
  const row = await credentialRepository.load(db, projectId, name);
  if (row === null) throw new Error(`expected a stored credential "${name}"`);
  return row.generation;
}

/** The generation rule spans the row's lifetime via the epoch-millisecond clock, so two writes inside
 *  the same millisecond could tie; real flows are separated by whole OAuth round-trips, tests by this. */
function nextMillisecond(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 2));
}

describe.skipIf(!databaseAvailable)("credentialRepository", () => {
  const projectId = randomUUID();

  beforeAll(async () => {
    // A throwaway project row for the credential FK; the afterAll delete cascades the credentials away.
    await db.insert(projects).values({ id: projectId, name: `mcp-credential-test-${projectId}` });
  });

  afterAll(async () => {
    await db.delete(projects).where(eq(projects.id, projectId));
  });

  test("upsert stores the value and every replace strictly raises the generation", async () => {
    await credentialRepository.upsert(db, projectId, "github", "sealed-1", "mcp");
    const first = await credentialRepository.load(db, projectId, "github");
    expect(first?.value).toBe("sealed-1");

    await credentialRepository.upsert(db, projectId, "github", "sealed-2", "mcp");
    const second = await credentialRepository.load(db, projectId, "github");
    expect(second?.value).toBe("sealed-2");
    expect(second?.generation).toBeGreaterThan(first?.generation ?? Number.POSITIVE_INFINITY);
  });

  test("saveWithGeneration lands only while the row still holds the generation it read", async () => {
    await credentialRepository.upsert(db, projectId, "cas", "sealed-original", "mcp");
    const read = await generationOf(projectId, "cas");

    // The rotation that read the current generation wins and moves the row past it…
    expect(
      await credentialRepository.saveWithGeneration(db, projectId, "cas", "sealed-rotated", read),
    ).toBe(true);
    const afterRotation = await credentialRepository.load(db, projectId, "cas");
    expect(afterRotation?.value).toBe("sealed-rotated");
    expect(afterRotation?.generation).toBeGreaterThan(read);

    // …so a second write-back still carrying the pre-rotation generation is refused, row unchanged.
    expect(
      await credentialRepository.saveWithGeneration(db, projectId, "cas", "sealed-stale", read),
    ).toBe(false);
    expect(await credentialRepository.load(db, projectId, "cas")).toEqual(afterRotation);
  });

  test("a completed authorization's upsert defeats a refresh that read the previous generation", async () => {
    await credentialRepository.upsert(db, projectId, "race", "sealed-old", "mcp");
    const read = await generationOf(projectId, "race");

    // A re-authorization lands between the refresh's read and its write-back…
    await credentialRepository.upsert(db, projectId, "race", "sealed-fresh-grant", "mcp");

    // …so the refresh's compare-and-set against the old generation loses.
    expect(
      await credentialRepository.saveWithGeneration(db, projectId, "race", "sealed-refresh", read),
    ).toBe(false);
    expect((await credentialRepository.load(db, projectId, "race"))?.value).toBe(
      "sealed-fresh-grant",
    );
  });

  test("a stale refresh from before a forget never clobbers the re-authorized credential", async () => {
    // The ABA scenario: authorize → the provider loads its generation → the operator forgets the
    // credential (switching accounts) → a NEW authorization creates a fresh row. The refresh
    // write-back still holding the pre-forget generation must not match the new row — that would hand
    // the old account's rotated tokens to the credential the new account just established.
    await credentialRepository.upsert(db, projectId, "switch", "sealed-old-account", "mcp");
    const preForgetGeneration = await generationOf(projectId, "switch");

    expect(await credentialRepository.delete(db, projectId, "switch")).toBe(true);
    await nextMillisecond();
    await credentialRepository.upsert(db, projectId, "switch", "sealed-new-account", "mcp");

    expect(
      await credentialRepository.saveWithGeneration(
        db,
        projectId,
        "switch",
        "sealed-stale-refresh",
        preForgetGeneration,
      ),
    ).toBe(false);
    const surviving = await credentialRepository.load(db, projectId, "switch");
    expect(surviving?.value).toBe("sealed-new-account");
    expect(surviving?.generation).toBeGreaterThan(preForgetGeneration);
  });

  test("saveWithGeneration never resurrects a deleted credential", async () => {
    await credentialRepository.upsert(db, projectId, "forgotten", "sealed-1", "mcp");
    const read = await generationOf(projectId, "forgotten");
    expect(await credentialRepository.delete(db, projectId, "forgotten")).toBe(true);

    expect(
      await credentialRepository.saveWithGeneration(
        db,
        projectId,
        "forgotten",
        "sealed-back",
        read,
      ),
    ).toBe(false);
    expect(await credentialRepository.load(db, projectId, "forgotten")).toBeNull();
  });

  test("list shows metadata only, and delete reports absence", async () => {
    await credentialRepository.upsert(db, projectId, "list-b", "sealed-b", "mcp");
    await credentialRepository.upsert(db, projectId, "list-a", "sealed-a", "configured");

    const listed = await credentialRepository.list(db, projectId);
    const names = listed.map((entry) => entry.name);
    expect(names).toContain("list-a");
    expect(names).toContain("list-b");
    // Name-ordered, and no sealed value in the listing shape — but the profile discriminant IS there
    // (the admin dispatches mcp-vs-configured on it; it is how the credential was acquired, not a secret).
    expect(names.indexOf("list-a")).toBeLessThan(names.indexOf("list-b"));
    expect(listed.find((entry) => entry.name === "list-a")?.profile).toBe("configured");
    expect(listed.find((entry) => entry.name === "list-b")?.profile).toBe("mcp");
    for (const entry of listed) {
      expect(entry.updatedAt).toBeInstanceOf(Date);
      expect(Object.keys(entry).sort()).toEqual(["name", "profile", "updatedAt"]);
    }

    expect(await credentialRepository.delete(db, projectId, "list-a")).toBe(true);
    expect(await credentialRepository.delete(db, projectId, "list-a")).toBe(false);
  });

  test("a re-deposit through the other acquisition path switches the profile discriminant", async () => {
    await credentialRepository.upsert(db, projectId, "switcher", "sealed-mcp", "mcp");
    await credentialRepository.upsert(db, projectId, "switcher", "sealed-conf", "configured");
    const listed = await credentialRepository.list(db, projectId);
    expect(listed.find((entry) => entry.name === "switcher")?.profile).toBe("configured");
  });

  test("load returns null for a name never stored", async () => {
    expect(await credentialRepository.load(db, projectId, "never-stored")).toBeNull();
  });
});
