// The `oauth_clients` registry as the admin API presents it (docs/2026-07-14-credentials-core.md Phase 2
// §3): register / list / delete, with the client secret WRITE-ONLY — deposited by a PUT, sealed at rest,
// read back only by the runtime's own token exchange / refresh, never returned over the list API. A null
// secret is a genuine absence (a public client). Runs against the real Postgres schema (the seal + the
// composite key are the point) and skips when no database is reachable.

import { randomUUID } from "node:crypto";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import { closeDb, db } from "../src/db/client.js";
import { oauthClients } from "../src/db/tables/oauth-clients.js";
import { projects } from "../src/db/tables/projects.js";
import { NotFoundError } from "../src/lib/errors.js";
import { oauthClientRepository } from "../src/modules/oauth-client/oauth-client.repository.js";
import { oauthClientService } from "../src/modules/oauth-client/oauth-client.service.js";

const databaseAvailable = await (async () => {
  try {
    await db.select({ name: oauthClients.name }).from(oauthClients).limit(1);
    return true;
  } catch {
    return false;
  }
})();

afterAll(() => closeDb());

const CLIENT = {
  issuer: "https://idp.example.test",
  authorizeEndpoint: "https://idp.example.test/authorize",
  tokenEndpoint: "https://idp.example.test/token",
  clientId: "client-abc",
  clearSecret: false,
  scopes: ["read", "write"],
  authorizationParameters: {},
};

describe.skipIf(!databaseAvailable)("oauthClientService", () => {
  const projectId = randomUUID();

  beforeAll(async () => {
    await db.insert(projects).values({ id: projectId, name: `oauth-client-test-${projectId}` });
  });

  afterAll(async () => {
    await db.delete(projects).where(eq(projects.id, projectId));
  });

  test("registers a confidential client; the secret is sealed at rest and never listed", async () => {
    await oauthClientService.upsert(projectId, "salesforce", {
      ...CLIENT,
      clientSecret: "s3cr3t",
    });

    // The list is metadata only: it says a secret EXISTS (hasSecret) but never carries it, and no field
    // holds the secret value.
    const { clients } = await oauthClientService.list(projectId);
    const listed = clients.find((client) => client.name === "salesforce");
    expect(listed).toMatchObject({
      name: "salesforce",
      clientId: "client-abc",
      hasSecret: true,
      scopes: ["read", "write"],
    });
    expect(JSON.stringify(listed)).not.toContain("s3cr3t");

    // At rest the secret is AES-GCM sealed, not plaintext.
    const stored = await oauthClientRepository.load(db, projectId, "salesforce");
    expect(stored?.sealedSecret).not.toBeNull();
    expect(stored?.sealedSecret).not.toBe("s3cr3t");

    // The runtime's own reads unseal it (the token exchange / the credentials-core refresh).
    const config = await oauthClientService.loadConfig(projectId, "salesforce");
    expect(config?.clientSecret).toBe("s3cr3t");
    const credentials = await oauthClientService.resolveClientCredentials(projectId, "salesforce");
    expect(credentials).toEqual({ clientId: "client-abc", clientSecret: "s3cr3t" });
  });

  test("registers a public client (no secret) — a genuine absence, not a missing lookup", async () => {
    await oauthClientService.upsert(projectId, "stripe", CLIENT);

    const { clients } = await oauthClientService.list(projectId);
    expect(clients.find((client) => client.name === "stripe")?.hasSecret).toBe(false);
    const credentials = await oauthClientService.resolveClientCredentials(projectId, "stripe");
    expect(credentials).toEqual({ clientId: "client-abc", clientSecret: null });
  });

  test("authorization parameters round-trip readably (registry data, not a secret)", async () => {
    // Unlike the client secret, the extra authorize parameters are plain provider configuration: a PUT
    // stores them and the GET returns them, so the register form can show what is in effect.
    const parameters = { access_type: "offline", prompt: "consent" };
    await oauthClientService.upsert(projectId, "google", {
      ...CLIENT,
      authorizationParameters: parameters,
    });

    const { clients } = await oauthClientService.list(projectId);
    expect(clients.find((client) => client.name === "google")?.authorizationParameters).toEqual(
      parameters,
    );
    // The flow's own read carries them too — what the authorize-URL construction appends.
    const config = await oauthClientService.loadConfig(projectId, "google");
    expect(config?.authorizationParameters).toEqual(parameters);
  });

  test("re-registering WITHOUT a secret keeps the stored one (the write-only field cannot round-trip)", async () => {
    await oauthClientService.upsert(projectId, "rotating", { ...CLIENT, clientSecret: "first" });
    expect(
      (await oauthClientService.resolveClientCredentials(projectId, "rotating"))?.clientSecret,
    ).toBe("first");
    // A replace whose secret field is absent keeps the current secret — the form cannot echo a
    // write-only value back, so absence must not silently downgrade the client to public (which would
    // kill its refreshes). The plain fields still replace.
    await oauthClientService.upsert(projectId, "rotating", { ...CLIENT, clientId: "client-v2" });
    expect(await oauthClientService.resolveClientCredentials(projectId, "rotating")).toEqual({
      clientId: "client-v2",
      clientSecret: "first",
    });
    // A new secret replaces the kept one.
    await oauthClientService.upsert(projectId, "rotating", { ...CLIENT, clientSecret: "second" });
    expect(
      (await oauthClientService.resolveClientCredentials(projectId, "rotating"))?.clientSecret,
    ).toBe("second");
  });

  test("clearSecret is the explicit downgrade to a public client", async () => {
    await oauthClientService.upsert(projectId, "downgrade", { ...CLIENT, clientSecret: "gone" });
    await oauthClientService.upsert(projectId, "downgrade", { ...CLIENT, clearSecret: true });
    expect(await oauthClientService.resolveClientCredentials(projectId, "downgrade")).toEqual({
      clientId: "client-abc",
      clientSecret: null,
    });
    expect(
      (await oauthClientService.list(projectId)).clients.find(
        (client) => client.name === "downgrade",
      )?.hasSecret,
    ).toBe(false);
  });

  test("resolving an unregistered client is null (the refresh then parks for re-login)", async () => {
    expect(await oauthClientService.resolveClientCredentials(projectId, "unknown")).toBeNull();
    expect(await oauthClientService.loadConfig(projectId, "unknown")).toBeNull();
  });

  test("delete removes the client; a second delete is a 404", async () => {
    await oauthClientService.upsert(projectId, "gone", CLIENT);
    await oauthClientService.delete(projectId, "gone");
    expect(await oauthClientRepository.load(db, projectId, "gone")).toBeNull();
    await expect(oauthClientService.delete(projectId, "gone")).rejects.toThrowError(NotFoundError);
  });
});
