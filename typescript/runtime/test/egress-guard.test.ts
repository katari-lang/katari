// The outbound destination guard. A katari program picks `http.fetch`'s url at runtime, so its value can
// come from an LLM's output or a webhook payload; these tests pin the ranges that must stay unreachable —
// above all the link-local block the cloud metadata services sit in, which is what turns an SSRF into
// stolen credentials.

import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { afterAll, beforeAll, describe, expect, test } from "vitest";
import {
  BlockedDestinationError,
  createGuardedFetch,
  isBlockedAddress,
  readBodyWithLimit,
} from "../src/runtime/external/egress-guard.js";

describe("isBlockedAddress", () => {
  test.each([
    ["169.254.169.254", "the EC2 instance metadata service"],
    ["169.254.170.2", "the ECS task credentials endpoint"],
    ["127.0.0.1", "loopback"],
    ["10.1.2.3", "RFC 1918"],
    ["172.16.0.1", "RFC 1918"],
    ["192.168.1.1", "RFC 1918"],
    ["100.64.0.1", "carrier-grade NAT"],
    ["0.0.0.0", "the unspecified address"],
    ["::1", "IPv6 loopback"],
    ["fe80::1", "IPv6 link-local"],
    ["fd00::1", "IPv6 unique-local"],
  ])("blocks %s (%s)", (address) => {
    expect(isBlockedAddress(address)).toBe(true);
  });

  test.each([["1.1.1.1"], ["8.8.8.8"], ["93.184.216.34"], ["2606:4700:4700::1111"]])(
    "allows the public address %s",
    (address) => {
      expect(isBlockedAddress(address)).toBe(false);
    },
  );

  // Mapping a v4 address into v6 is the obvious way to try to slip past rules written for v4, so the
  // normalization that defeats it is worth pinning rather than leaving implied.
  test("blocks an IPv4-mapped IPv6 form of a blocked address", () => {
    expect(isBlockedAddress("::ffff:169.254.169.254")).toBe(true);
    expect(isBlockedAddress("::ffff:127.0.0.1")).toBe(true);
  });

  test("does not block an IPv4-mapped IPv6 form of a public address", () => {
    expect(isBlockedAddress("::ffff:8.8.8.8")).toBe(false);
  });
});

describe("createGuardedFetch", () => {
  const policy = { allowPrivateAddresses: false, allowedHosts: new Set<string>() };

  test("refuses a literal link-local destination", async () => {
    const guarded = createGuardedFetch(policy, 1_000);
    await expect(
      guarded("http://169.254.169.254/latest/meta-data/iam/security-credentials/"),
    ).rejects.toThrow(BlockedDestinationError);
  });

  test("refuses a loopback destination", async () => {
    const guarded = createGuardedFetch(policy, 1_000);
    await expect(guarded("http://127.0.0.1:18099/anything")).rejects.toThrow(BlockedDestinationError);
  });

  // The scheme check is separate from the address check: `file:` never reaches DNS at all, so it has to be
  // refused up front rather than by the lookup.
  test.each([["file:///etc/passwd"], ["data:text/plain,hello"], ["ftp://example.test/x"]])(
    "refuses the non-http scheme in %s",
    async (url) => {
      const guarded = createGuardedFetch(policy, 1_000);
      await expect(guarded(url)).rejects.toThrow(BlockedDestinationError);
    },
  );

  test("an exempt host reaches a private address, which is what the escape hatch is for", async () => {
    const server = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "text/plain" });
      response.end("reached");
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    const { port } = server.address() as AddressInfo;
    try {
      const guarded = createGuardedFetch(
        { allowPrivateAddresses: false, allowedHosts: new Set(["127.0.0.1"]) },
        1_000,
      );
      const response = await guarded(`http://127.0.0.1:${port}/`);
      expect(await response.text()).toBe("reached");
    } finally {
      server.close();
    }
  });
});

describe("readBodyWithLimit", () => {
  let server: Server;
  let base: string;

  beforeAll(async () => {
    server = createServer((_request, response) => {
      response.writeHead(200, { "content-type": "application/octet-stream" });
      // Comfortably more than the small ceiling the tests below apply.
      response.end(Buffer.alloc(64 * 1024, 1));
    });
    await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
    base = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });

  afterAll(() => {
    server.close();
  });

  test("rejects a body past the ceiling instead of buffering it", async () => {
    const guarded = createGuardedFetch(
      { allowPrivateAddresses: true, allowedHosts: new Set() },
      1_000,
    );
    const response = await guarded(`${base}/big`);
    await expect(readBodyWithLimit(response, 1024)).rejects.toThrow(/exceeds the 1024-byte limit/);
  });

  test("returns a body that fits", async () => {
    const guarded = createGuardedFetch(
      { allowPrivateAddresses: true, allowedHosts: new Set() },
      1_000,
    );
    const response = await guarded(`${base}/big`);
    const bytes = await readBodyWithLimit(response, 128 * 1024);
    expect(bytes.length).toBe(64 * 1024);
  });
});
