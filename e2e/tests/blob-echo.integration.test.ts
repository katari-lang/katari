// Real-subprocess FFI blob round-trip through the value data plane.
//
// The lightest end-to-end exercise of Phase C: a REAL bundled sidecar (the
// 23-blob-echo sample) talks to a REAL running data plane (the api-server test
// harness, in-memory storage — no Postgres) using the Katari Protocol env the
// host stamps onto a sidecar. `makeBlob` produces a value-store blob via
// katari.value.put; `readBlob` consumes it back via katari.value.text. This is
// where the env wiring (KATARI_PROTOCOL_URL/_TOKEN/_PROJECT_ID/_SIDECAR_OWNER)
// actually gets used by katari-port against a live server.
//
// (The full ktr `apply`→`run` path additionally needs a fresh `katari` binary
// for the `file` type; that is the docker/`stack exec` route. This test covers
// the produce/consume data-plane half without the compiler.)

import { resolve } from "node:path";
import { startHttpHarness } from "@katari-lang/api-server/tests/helpers.js";
import { bundleSidecar } from "@katari-lang/bundle";
import {
  type AgentDefId,
  type ChildToParent,
  type DelegationId,
  loadSubprocessSidecar,
  noopLogger,
  type RawValue,
  type Sidecar,
} from "@katari-lang/runtime";
import { afterEach, describe, expect, it } from "vitest";

const SAMPLE_ROOT = resolve(__dirname, "../samples/23-blob-echo/src");

let activeSidecar: Sidecar | null = null;
let activeHarness: { shutdown: () => Promise<void> } | null = null;
afterEach(async () => {
  if (activeSidecar !== null) {
    await activeSidecar.shutdown().catch(() => {});
    activeSidecar = null;
  }
  if (activeHarness !== null) {
    await activeHarness.shutdown().catch(() => {});
    activeHarness = null;
  }
});

async function waitForAck(
  received: ChildToParent[],
  fromIndex: number,
): Promise<Extract<ChildToParent, { type: "ipcDelegateAck" }>> {
  const deadline = Date.now() + 8000;
  while (Date.now() < deadline) {
    const ack = received.slice(fromIndex).find((m) => m.type === "ipcDelegateAck");
    if (ack !== undefined && ack.type === "ipcDelegateAck") return ack;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`no ipcDelegateAck within timeout (received: ${JSON.stringify(received)})`);
}

describe("FFI blob round-trip — real sidecar against a live data plane", () => {
  it("makeBlob produces a file ref; readBlob consumes it back to text", async () => {
    const harness = await startHttpHarness();
    activeHarness = harness;

    const result = await bundleSidecar({
      packages: [{ packageName: "blob_echo", sourceRoot: SAMPLE_ROOT }],
    });
    expect(result).not.toBeNull();

    const sidecar = await loadSubprocessSidecar({
      bundle: result!.bundle,
      logger: noopLogger,
      // The coordinates the actor host would stamp (see ApiServerActorHost):
      env: {
        KATARI_PROTOCOL_URL: harness.url,
        KATARI_PROTOCOL_TOKEN: "test-token",
        KATARI_PROJECT_ID: "proj-1",
        KATARI_SIDECAR_OWNER: "ffi",
      },
    });
    activeSidecar = sidecar;

    const received: ChildToParent[] = [];
    sidecar.onMessage((m) => received.push(m));
    await sidecar.start();

    // 1. makeBlob → ext writes bytes to the data plane, returns a file ref.
    await sidecar.send({
      type: "ipcDelegate",
      delegationId: "d-make" as DelegationId,
      agentDefId: "blob_echo.makeBlob" as AgentDefId,
      args: { text: "hello blob" },
    });
    const makeAck = await waitForAck(received, 0);
    const ref = makeAck.value as Record<string, unknown>;
    expect(ref.$ref).toBeDefined();
    expect(ref.as).toBe("file");
    expect((ref.$ref as Record<string, unknown>).module).toBe("ffi");

    // 2. readBlob(that ref) → ext fetches the bytes back and decodes them.
    const before = received.length;
    await sidecar.send({
      type: "ipcDelegate",
      delegationId: "d-read" as DelegationId,
      agentDefId: "blob_echo.readBlob" as AgentDefId,
      args: { blob: makeAck.value as RawValue },
    });
    const readAck = await waitForAck(received, before);
    expect(readAck.value).toBe("hello blob");
  }, 30000);
});
