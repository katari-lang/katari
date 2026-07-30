// The egress guard: the one place a PROGRAM-chosen destination is checked before the runtime connects to it.
// Both outbound transports go through it — `http.fetch` (`http-transport.ts`) and the MCP client
// (`mcp-transport.ts`, which takes the guarded `fetch` as its `FetchLike`).
//
// Why this exists at all. A katari program picks `http.fetch`'s `url` and an MCP server descriptor's `url` at
// RUNTIME: both are plain public `string`s, so their value can come from an LLM's output, a webhook payload,
// or a tool result. The type system tracks CONFIDENTIALITY (a `private` value may only leave toward the
// destination server), not INTEGRITY — nothing upstream establishes that a URL is one the operator intended.
// Unguarded, a prompt-injected agent can therefore point the runtime at the cloud metadata service
// (169.254.169.254, or 169.254.170.2 on ECS — an arbitrary method plus arbitrary headers is all IMDSv2 asks
// for) or at anything else reachable inside the deployment's private network.
//
// Why the check lives in the dispatcher's `lookup` rather than at URL-parse time. Validating the parsed
// hostname and then handing the URL to `fetch` re-resolves the name a second time, so a name that answers
// with a public address on the first query and a private one on the second (DNS rebinding) would slip
// through. Checking the address the socket is actually about to connect to closes that window, and it covers
// redirects for free: every hop opens a new connection, so every hop is checked the same way. A program can
// therefore not launder a blocked destination through a public host that 302s to it.

import { lookup as dnsLookup } from "node:dns";
import { BlockList, isIP, isIPv4, type LookupFunction } from "node:net";
import { Agent, type RequestInit, type Response, fetch as undiciFetch } from "undici";

/** Raised when a destination resolves to an address the guard refuses to connect to. Distinct from a
 *  transport error so the callers can phrase it as the deliberate refusal it is rather than as a network
 *  fault the program should retry. */
export class BlockedDestinationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BlockedDestinationError";
  }
}

/** How the guard is configured. `allowPrivateAddresses` disables the address check outright (a development
 *  escape hatch — a laptop legitimately fetches `localhost`); `allowedHosts` exempts named hosts instead,
 *  which is what a deployment with one genuine internal dependency wants. */
export interface EgressPolicy {
  allowPrivateAddresses: boolean;
  allowedHosts: ReadonlySet<string>;
}

/** The address ranges a program-chosen destination may never reach. Loopback and the RFC 1918 blocks keep a
 *  program off the host and the VPC; 169.254.0.0/16 and fe80::/10 are the link-local ranges the cloud
 *  metadata services sit in, which is the range that actually turns an SSRF into stolen credentials. The rest
 *  (0.0.0.0/8, the carrier-grade NAT block, the benchmarking and multicast and reserved ranges) are addresses
 *  no legitimate API is served from, so blocking them costs nothing and removes a class of surprises. */
function buildBlockList(): BlockList {
  const blocked = new BlockList();
  blocked.addSubnet("0.0.0.0", 8, "ipv4");
  blocked.addSubnet("10.0.0.0", 8, "ipv4");
  blocked.addSubnet("100.64.0.0", 10, "ipv4");
  blocked.addSubnet("127.0.0.0", 8, "ipv4");
  blocked.addSubnet("169.254.0.0", 16, "ipv4");
  blocked.addSubnet("172.16.0.0", 12, "ipv4");
  blocked.addSubnet("192.0.0.0", 24, "ipv4");
  blocked.addSubnet("192.168.0.0", 16, "ipv4");
  blocked.addSubnet("198.18.0.0", 15, "ipv4");
  blocked.addSubnet("224.0.0.0", 4, "ipv4");
  blocked.addSubnet("240.0.0.0", 4, "ipv4");
  blocked.addAddress("::", "ipv6");
  blocked.addAddress("::1", "ipv6");
  blocked.addSubnet("fc00::", 7, "ipv6");
  blocked.addSubnet("fe80::", 10, "ipv6");
  blocked.addSubnet("ff00::", 8, "ipv6");
  return blocked;
}

const blockList = buildBlockList();

/** Reduce an IPv4-mapped IPv6 address (`::ffff:169.254.169.254`) to the IPv4 address it denotes, so the v4
 *  ranges above catch it. Without this, mapping is a trivial bypass of every v4 rule. Any other address is
 *  returned unchanged. */
function normalizeAddress(address: string): string {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(address);
  return mapped?.[1] ?? address;
}

/** Whether an address is one the guard refuses. Exported for the unit tests, which assert the ranges
 *  directly rather than going through a socket. */
export function isBlockedAddress(address: string): boolean {
  const normalized = normalizeAddress(address);
  return blockList.check(normalized, isIPv4(normalized) ? "ipv4" : "ipv6");
}

/** The message a refusal carries. It names the address as well as the host, because a hostname that
 *  resolves somewhere unexpected is exactly the case an operator needs to see spelled out. */
function refusalMessage(hostname: string, address: string): string {
  return (
    `refusing to connect to "${hostname}" (${address}): it resolves to a loopback, private, or link-local ` +
    "address. The runtime blocks these so a program-chosen URL cannot reach the deployment's internal " +
    "network or the cloud metadata service. Allow it with KATARI_EGRESS_ALLOWED_HOSTS=<host> if the " +
    "destination is genuinely intended, or KATARI_EGRESS_ALLOW_PRIVATE=true for local development."
  );
}

/** The `lookup` the guarded dispatcher connects through: resolve as usual, then refuse the connection if any
 *  address the socket could use is blocked. Node calls this with `all: true` in some paths and without it in
 *  others, so both result shapes are handled; when `all` is set EVERY candidate must pass, since the socket
 *  is free to pick any of them. */
const guardedLookup: LookupFunction = (hostname, options, callback) => {
  dnsLookup(hostname, options, (error, address, family) => {
    if (error !== null) {
      callback(error, address, family);
      return;
    }
    const candidates = Array.isArray(address) ? address.map((entry) => entry.address) : [address];
    const refused = candidates.find((candidate) => isBlockedAddress(candidate));
    if (refused !== undefined) {
      callback(new BlockedDestinationError(refusalMessage(hostname, refused)), address, family);
      return;
    }
    callback(null, address, family);
  });
};

/** The dispatcher pair a guarded fetch picks between: the checking one for ordinary destinations, and a
 *  plain one for hosts the policy exempts (an exemption must bypass the address check, not merely the
 *  hostname match — the whole point is that the operator vouched for that host). */
interface Dispatchers {
  guarded: Agent;
  exempt: Agent;
}

/** Only http(s) may be dialled. `fetch` would also accept `data:` and `blob:`, which are not network
 *  destinations and have no business being reachable from a program's URL string; anything else (`file:`,
 *  a custom scheme) is rejected outright rather than left to the platform to interpret. */
const ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);

/** A `fetch` bound to one policy: the shape both transports take, and the MCP SDK's `FetchLike`. */
export type GuardedFetch = (url: string | URL, init?: RequestInit) => Promise<Response>;

/** Build the guarded `fetch` for a policy. The dispatchers are created once and shared across every request
 *  the runtime makes through it, so connection pooling still works. */
export function createGuardedFetch(policy: EgressPolicy, connectTimeoutMs: number): GuardedFetch {
  const dispatchers: Dispatchers = {
    guarded: new Agent({ connect: { lookup: guardedLookup, timeout: connectTimeoutMs } }),
    exempt: new Agent({ connect: { timeout: connectTimeoutMs } }),
  };
  return async (url, init) => {
    const target = url instanceof URL ? url : new URL(url);
    if (!ALLOWED_PROTOCOLS.has(target.protocol)) {
      throw new BlockedDestinationError(
        `refusing to request "${target.protocol}" — only http and https destinations are allowed`,
      );
    }
    const exempted = policy.allowPrivateAddresses || policy.allowedHosts.has(target.hostname);
    // A hostname that is ALREADY an IP literal never reaches the dispatcher's `lookup` — `net.connect`
    // dials it directly — so the literal case has to be checked here. This is not an edge case worth
    // deferring: `http://169.254.169.254/…` is the single most likely way an SSRF is actually attempted,
    // and it is exactly the shape that would slip past a resolver-only guard.
    // `URL` brackets an IPv6 host (`[::1]`), so strip them before asking.
    const literal = target.hostname.replace(/^\[|\]$/g, "");
    if (!exempted && isIP(literal) !== 0 && isBlockedAddress(literal)) {
      throw new BlockedDestinationError(refusalMessage(target.hostname, literal));
    }
    const dispatcher = exempted ? dispatchers.exempt : dispatchers.guarded;
    try {
      return await undiciFetch(target, { ...init, dispatcher });
    } catch (error) {
      // A refusal raised inside the dispatcher's `lookup` reaches us wrapped as undici's generic
      // `TypeError: fetch failed`, with the real reason on `cause`. Unwrap it so the caller sees the
      // deliberate policy decision rather than a nondescript network failure — the difference matters,
      // because one is worth telling an operator about and the other is not.
      throw unwrapBlocked(error);
    }
  };
}

/** Recover a `BlockedDestinationError` from however undici wrapped it, or return the error unchanged. */
function unwrapBlocked(error: unknown): unknown {
  if (error instanceof BlockedDestinationError) return error;
  if (error instanceof Error && error.cause !== undefined) return unwrapBlocked(error.cause);
  return error;
}

/** A guarded fetch that permits private addresses — exactly what `KATARI_EGRESS_ALLOW_PRIVATE=true`
 *  produces. It is what the tests dial their local servers through, so they exercise the real code path
 *  rather than a stub, and the scheme check still applies. Not a way to skip the guard in production: the
 *  policy there comes from `config`, and this constructs its own. */
export function createLocalFetch(): GuardedFetch {
  return createGuardedFetch({ allowPrivateAddresses: true, allowedHosts: new Set() }, 10_000);
}

/** Read a response body with a hard byte ceiling, so a hostile or merely enormous response cannot exhaust
 *  the runtime's heap — the process is shared by every project, so one oversized download is an availability
 *  problem for all of them. Streaming rather than `arrayBuffer()` is the point: the cap is enforced as the
 *  bytes arrive, so the limit is never allocated in the first place. */
export async function readBodyWithLimit(response: Response, maxBytes: number): Promise<Uint8Array> {
  const body = response.body;
  if (body === null) return new Uint8Array(0);
  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = body.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error(
        `the response body exceeds the ${maxBytes}-byte limit (KATARI_HTTP_MAX_RESPONSE_BYTES)`,
      );
    }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    joined.set(chunk, offset);
    offset += chunk.length;
  }
  return joined;
}
