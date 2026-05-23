// Real-subprocess integration test for the FFI sidecar transport.
//
// Walks the 11-ext-agent sample's source root through `bundleSidecar`
// (= the same path `katari apply` uses), then spawns the resulting
// bundle via `loadSubprocessSidecar` and exercises the protocol v2
// round-trip end-to-end:
//
//   - parent: `ipcDelegate` { args: { name: "world" } }
//   - child:  `ipcDelegateAck` { value: "hello, world" }
//
// The bundle imports katari-port (= IPC client) and registers
// `katari.agent("extGreet", ...)` from main.ts.

import { afterEach, describe, expect, it } from "vitest";
import { resolve } from "node:path";
import { bundleSidecar } from "@katari-lang/bundle";
import {
  loadSubprocessSidecar,
  noopLogger,
  type AgentDefId,
  type ChildToParent,
  type DelegationId,
  type Sidecar,
} from "@katari-lang/runtime";

const SAMPLE_ROOT = resolve(__dirname, "../samples/11-ext-agent/src");
const CRON_SAMPLE_ROOT = resolve(__dirname, "../samples/12-ext-cron/src");

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
  it("round-trips ipcDelegate → ipcDelegateAck for 11-ext-agent", async () => {
    const result = await bundleSidecar({
      packages: [{ packageName: "ext_agent", sourceRoot: SAMPLE_ROOT }],
    });
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
      type: "ipcDelegate",
      delegationId: "delegation-1" as DelegationId,
      // The bundle's __withModule plugin prefixes the agent name with
      // the file's module qname; ext_agent.ts → "ext_agent".
      agentDefId: "ext_agent.extGreet" as unknown as Parameters<
        Sidecar["send"]
      >[0] extends { agentDefId: infer A }
        ? A
        : never,
      args: { name: "world" },
    });

    const deadline = Date.now() + 5000;
    while (
      Date.now() < deadline &&
      !received.some((m) => m.type === "ipcDelegateAck")
    ) {
      await new Promise((r) => setTimeout(r, 20));
    }
    const ack = received.find((m) => m.type === "ipcDelegateAck");
    if (ack === undefined || ack.type !== "ipcDelegateAck") {
      throw new Error(
        `no ipcDelegateAck within timeout (received: ${JSON.stringify(received)})`,
      );
    }
    expect(ack.value).toBe("hello, world");
  });

  it("12-ext-cron: ext emits ipcChildDelegate for the callback and honours ipcTerminate", async () => {
    const result = await bundleSidecar({
      packages: [{ packageName: "ext_cron", sourceRoot: CRON_SAMPLE_ROOT }],
    });
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

    // Invoke cron_impl with a callback qname.
    await sidecar.send({
      type: "ipcDelegate",
      delegationId: "cron-delegation-1" as DelegationId,
      agentDefId: "ext_cron.cron_impl" as AgentDefId,
      args: { callback: "ext_cron.notify_scheduled" },
    });

    // Wait for the ext to emit ipcChildDelegate.
    const childDeadline = Date.now() + 5000;
    while (
      Date.now() < childDeadline &&
      !received.some((m) => m.type === "ipcChildDelegate")
    ) {
      await new Promise((r) => setTimeout(r, 20));
    }
    const childDelegate = received.find((m) => m.type === "ipcChildDelegate");
    if (childDelegate === undefined || childDelegate.type !== "ipcChildDelegate") {
      throw new Error(
        `no ipcChildDelegate within timeout (received: ${JSON.stringify(received)})`,
      );
    }
    expect(childDelegate.agentDefId).toBe("ext_cron.notify_scheduled");
    expect(childDelegate.parentDelegationId).toBe("cron-delegation-1");

    // Pretend CORE finished the child agent successfully.
    await sidecar.send({
      type: "ipcChildDelegateAck",
      delegationId: childDelegate.delegationId,
      value: null,
    });

    // Ext is now stuck in its never-return Promise; cancel it.
    await sidecar.send({
      type: "ipcTerminate",
      delegationId: "cron-delegation-1" as DelegationId,
    });

    const termDeadline = Date.now() + 5000;
    while (
      Date.now() < termDeadline &&
      !received.some((m) => m.type === "ipcTerminateAck")
    ) {
      await new Promise((r) => setTimeout(r, 20));
    }
    const terminateAck = received.find(
      (m) => m.type === "ipcTerminateAck",
    );
    if (terminateAck === undefined) {
      throw new Error(
        `no ipcTerminateAck within timeout (received: ${JSON.stringify(received)})`,
      );
    }
    expect(terminateAck.type).toBe("ipcTerminateAck");
  });
});
