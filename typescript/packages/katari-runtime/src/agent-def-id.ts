// AgentDefId: opaque, module-local agent identifier carried on
// `delegate` / `escalate` events.
//
// **Two namespaces.** The id has an EXTERNAL form (snapshot-bearing — what
// flows on the bus and inside an agent VALUE) and an INTERNAL form (the bare
// user-defined name, which lives per-snapshot inside the IR and the sidecar).
//
// **Wire format**: a flat string, one of two CORE flavours:
//   - `"main.foo@<snapshot>"` — a top-level callable in its EXTERNAL form. The
//     `@snapshot` says which IR version to run (a bare `"main.foo"` is the
//     internal id and is ambiguous on the wire — delegating one fails). It is
//     stamped in exactly two places: DelegateThread (a CORE/FFI delegate target)
//     and the front-end / API entry (building the id from a name + snapshot).
//   - `"closure:<closureId>"` — a closure, dispatched by its machine-local id
//     (a UUID) into the CORE-global closure store. A CORE-internal closure call
//     never emits a delegate (the call site spawns the body in-shard over the
//     captured scope); this wire form appears in a closure VALUE / `get_metadata.id`
//     / the JSON-Schema `$agent` carry, and on a cross-entity callback delegate
//     (e.g. FFI invoking a closure it received). The snapshot rides on the
//     closure record (not an `@` stamp). The id is process-local: a closure is
//     re-invocable only while its owner entity is alive in this project actor.
// Both callable wire forms (`qname@snapshot` | `closure:<id>`) flow end-to-end
// through CORE / FFI / API / sidecar / AI tool calls.
//
// **Branding**: each module owns its own opaque type wrapper around the
// raw string. `encodeCoreAgentDefId` / `encodeFfiAgentDefId` are the
// only way to construct one, and `decodeCoreAgentDefId` /
// `decodeFfiAgentDefId` are the only way to extract the underlying
// shape. The wire JSON is identical (both modules use plain strings),
// but the type checker prevents cross-namespace usage at code-edit
// time.
//
// **Closure prefix safety**: `:` is not a valid character in a Katari
// identifier (qname segments are `[A-Za-z_][A-Za-z0-9_]*`), so the
// `closure:` prefix can never collide with a real qname.

import type { ClosureId } from "./engine/id.js";
import type { QualifiedName } from "./ir/types.js";

// `:` is not a valid character in a Katari identifier (qname segments are
// `[A-Za-z_][A-Za-z0-9_]*`), so this prefix can never collide with a real qname.
const CLOSURE_PREFIX = "closure:";

/**
 * Qualified name of the language built-in `throw` request. This is Katari
 * language vocabulary (the compiler lowers `throw` / a handle scope's
 * `req throw` to this qname — see ConstraintGenerator: module `primitive`,
 * name `throw`), so every layer that raises or relays an error escalate
 * (engine runner, FFI sidecar error, ENV arg error) and the boundary that
 * detects an UNHANDLED throw (ApiModule) must agree on it. Centralised here as
 * the single source of truth: the previous scattered string literals had
 * drifted (`prim.throw` on the API side never matched the emitted
 * `primitive.throw`, so unhandled throws were silently recorded as open
 * escalations instead of failing the run).
 */
export const THROW_REQUEST_QNAME = "primitive.throw";

/**
 * Opaque agent identifier handled by the bus / middle layer. Only the
 * receiving module decodes it. Wire format is a flat string
 * (JSON-serializable / structuredClone-safe).
 */
export type AgentDefId = string & { readonly __brand: "AgentDefId" };

// ─── CORE encoding / decoding ──────────────────────────────────────────────

/** CORE module knows two flavours: a top-level callable's qname (snapshot-
 * stamped on the wire), or a closure's machine-local id (a UUID) into the
 * CORE-global closure store (the snapshot rides on the closure record). */
export type CoreAgentDefId =
  | { kind: "qname"; value: QualifiedName; snapshot?: string }
  | { kind: "closure"; value: ClosureId };

// `@` separates a qname from the snapshot it runs on. Safe: `@` appears in
// neither qname segments (`[A-Za-z_][A-Za-z0-9_]*`), snapshot UUIDs, nor the
// `closure:` prefix. The snapshot is the EXTERNAL form's version axis: the
// receiver reads it back to pick the new shard's IR. An agent VALUE / a
// `get_metadata.id` carries it too (the value's wire `$agent` IS this string).
// The compiled JSON-Schema `$agent` stays an open string (no enum); decode
// treats a missing `@` as "no snapshot" (an internal-form id on the wire).
const SNAPSHOT_SEP = "@";

export function encodeCoreAgentDefId(value: CoreAgentDefId): AgentDefId {
  if (value.kind === "closure") {
    return (CLOSURE_PREFIX + String(value.value)) as AgentDefId;
  }
  return (
    value.snapshot !== undefined ? `${value.value}${SNAPSHOT_SEP}${value.snapshot}` : value.value
  ) as AgentDefId;
}

export function decodeCoreAgentDefId(id: AgentDefId): CoreAgentDefId {
  const s = id as unknown as string;
  if (typeof s !== "string") {
    throw new Error(`agent-def-id: invalid CORE encoding: ${JSON.stringify(id)}`);
  }
  if (s.startsWith(CLOSURE_PREFIX)) {
    const closureId = s.slice(CLOSURE_PREFIX.length);
    if (closureId === "") {
      throw new Error(`agent-def-id: malformed closure id: ${JSON.stringify(s)}`);
    }
    return { kind: "closure", value: closureId as ClosureId };
  }
  const at = s.indexOf(SNAPSHOT_SEP);
  if (at >= 0) {
    return { kind: "qname", value: s.slice(0, at), snapshot: s.slice(at + 1) };
  }
  return { kind: "qname", value: s };
}

// ─── FFI encoding / decoding ───────────────────────────────────────────────
//
// FFI side currently only handles qualified-name dispatch — sidecars have
// no concept of "closure". The wire format is the same flat string CORE
// uses for the qname case; the decoder simply rejects anything that
// looks like a closure prefix as a fast invariant check.

export type FfiAgentDefId = { kind: "qname"; value: QualifiedName; snapshot?: string };

export function encodeFfiAgentDefId(value: FfiAgentDefId): AgentDefId {
  return (
    value.snapshot !== undefined ? `${value.value}${SNAPSHOT_SEP}${value.snapshot}` : value.value
  ) as AgentDefId;
}

export function decodeFfiAgentDefId(id: AgentDefId): FfiAgentDefId {
  const s = id as unknown as string;
  if (typeof s !== "string") {
    throw new Error(`agent-def-id: invalid FFI encoding: ${JSON.stringify(id)}`);
  }
  if (s.startsWith(CLOSURE_PREFIX)) {
    throw new Error(
      `agent-def-id: FFI received a closure-form AgentDefId (${JSON.stringify(s)}); FFI agents are dispatched by qname only`,
    );
  }
  const at = s.indexOf(SNAPSHOT_SEP);
  if (at >= 0) {
    return { kind: "qname", value: s.slice(0, at), snapshot: s.slice(at + 1) };
  }
  return { kind: "qname", value: s };
}

// ─── Snapshot stamp helpers (shared by CORE + FFI) ─────────────────────────
//
// The CORE and FFI qname encodings are byte-identical (`qname` or
// `qname@snapshot`), so these three helpers operate on the flat string via
// the CORE decoder (the only one that also understands `closure:`). They are
// the single place that knows "the snapshot rides inside the agent def id":
//   - CORE stamps the issuing shard's snapshot on an outbound delegate target.
//   - FFI strips it before talking to the sidecar (whose handler registry is
//     keyed by the bare qname — the sidecar already IS the right snapshot's
//     code) and stamps its own snapshot on a CORE child the ext spawns.
// Closures carry no `@` stamp (the snapshot rides on the closure record), so
// these helpers pass a closure id through unchanged.

/** The snapshot a snapshot-dependent delegate target runs on, or `undefined`
 *  for a bare qname / closure. */
export function agentDefIdSnapshot(id: AgentDefId): string | undefined {
  const decoded = decodeCoreAgentDefId(id);
  return decoded.kind === "qname" ? decoded.snapshot : undefined;
}

/** The agent def id with any snapshot stamp removed (bare qname / closure). */
export function stripAgentDefIdSnapshot(id: AgentDefId): AgentDefId {
  const decoded = decodeCoreAgentDefId(id);
  if (decoded.kind !== "qname") return id;
  return encodeCoreAgentDefId({ kind: "qname", value: decoded.value });
}

/** The closure id of a closure-form agent def id, or `undefined` otherwise. */
export function agentDefIdClosure(id: AgentDefId): ClosureId | undefined {
  const decoded = decodeCoreAgentDefId(id);
  return decoded.kind === "closure" ? decoded.value : undefined;
}
