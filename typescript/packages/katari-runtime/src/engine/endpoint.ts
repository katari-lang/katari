// Endpoint: opaque string identifying a participant in the protocol.
//
// Modeled after the old `katari-protocol` (ts-old/packages/katari-protocol):
// any URL-like string identifies a peer. The engine itself is one such peer,
// reachable via `core://katari` (or whatever the host registers it as).
// External peers (the HTTP API, FFI sidecars, future cores) are identified
// by their own URLs.
//
// Engine-internal logic only checks `event.from === self` / `event.to === self`
// to decide whether an event is inbound or outbound. The string-literal
// `"API" | "CORE" | "FFI"` distinction from the previous design is gone —
// the host layer (DelegationRouter) is responsible for routing.

export type Endpoint = string & { readonly __brand: "Endpoint" };

/** Build an Endpoint from a URL-like string. */
export function endpoint(url: string): Endpoint {
  return url as Endpoint;
}

/**
 * The conventional endpoint identifying the engine itself when no host has
 * supplied a more specific URL. Tests and small embeds default to this.
 */
export const CORE_ENDPOINT: Endpoint = "core://katari" as Endpoint;
