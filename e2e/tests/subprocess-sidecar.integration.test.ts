// Real-subprocess integration test for the FFI sidecar transport.
//
// Walks the 11-ext-agent sample's source root through `bundleSidecar`
// (= the same path `katari apply` uses), then spawns the resulting
// bundle via `loadSubprocessSidecar` and exercises the full 7-message
// protocol end-to-end:
//
//   - parent: `delegate` { args: { name: "world" } }
//   - child:  `delegateAck` { value: "hello, world" }
//
// The bundle imports katari-port (= IPC client) and registers
// `katari.agent("extGreet", ...)` from main.ts.

import { afterEach, describe, expect, it } from "vitest";
import { resolve } from "node:path";
import { bundleSidecar } from "katari-cli/services/bundle";
import {
  loadSubprocessSidecar,
  noopLogger,
  PROTOCOL_VERSION,
  type ChildToParent,
  type DelegationId,
  type Sidecar,
} from "katari-runtime";

const SAMPLE_ROOT = resolve(__dirname, "../samples/11-ext-agent/src");

let active: Sidecar | null = null;
afterEach(async () => {
  if (active !== null) {
    try {
      await active.shutdown();
    } catch {
      /* best effort */
    }
    active = null;
  }
});

describe("SubprocessSidecar — real Node subprocess", () => {
  it("round-trips delegate → delegateAck for 11-ext-agent", async () => {
    const result = await bundleSidecar({ sourceRoots: [SAMPLE_ROOT] });
    expect(result).not.toBeNull();
    const bundle = result!.bundle;

    const sidecar = await loadSubprocessSidecar({
      bundle,
      logger: noopLogger,
    });
    active = sidecar;

    const received: ChildToParent[] = [];
    sidecar.onMessage((msg) => {
      received.push(msg);
    });

    await sidecar.start();

    await sidecar.send({
      type: "delegate",
      protocolVersion: PROTOCOL_VERSION,
      delegationId: "delegation-1" as DelegationId,
      // The bundle's __withModule plugin prefixes the agent name with
      // the file's module qname; main.ts → "main".
      agentDefId: "main.extGreet" as unknown as Parameters<Sidecar["send"]>[0] extends { agentDefId: infer A } ? A : never,
      args: { name: "world" },
    });

    const deadline = Date.now() + 5000;
    while (
      Date.now() < deadline &&
      !received.some((m) => m.type === "delegateAck")
    ) {
      await new Promise((r) => setTimeout(r, 20));
    }
    const ack = received.find((m) => m.type === "delegateAck");
    if (ack === undefined || ack.type !== "delegateAck") {
      throw new Error(
        `no delegateAck within timeout (received: ${JSON.stringify(received)})`,
      );
    }
    expect(ack.value).toBe("hello, world");
  });
});
