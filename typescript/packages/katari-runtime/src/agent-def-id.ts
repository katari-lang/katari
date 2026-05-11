// AgentDefId: opaque, module-local agent identifier carried on
// `delegate` / `escalate` events.
//
// **Wire format**: a flat string. Either a 'QualifiedName' (e.g.
// `"main.foo"` or `"prim.add_two_numbers"`) for top-level agents, or a
// `"closure:N"` prefix-form for local closures (CORE only). This shape
// is identical to what `get_metadata` returns in its `id` field and to
// what JSON Schema declares for `$callable`, so the same string flows
// end-to-end through CORE / FFI / API / sidecar / AI tool calls.
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

const CLOSURE_PREFIX = "closure:";

/**
 * Bus / 中間層で扱う opaque な agent identifier。受信側 module だけが decode する。
 * Wire 形式は flat string (JSON-serializable / structuredClone-safe).
 */
export type AgentDefId = string & { readonly __brand: "AgentDefId" };

// ─── CORE encoding / decoding ──────────────────────────────────────────────

/** CORE module knows two flavours: a top-level callable's qname, or an
 * engine-allocated closure id. */
export type CoreAgentDefId =
  | { kind: "qname"; value: QualifiedName }
  | { kind: "closure"; value: ClosureId };

export function encodeCoreAgentDefId(value: CoreAgentDefId): AgentDefId {
  if (value.kind === "closure") {
    return (CLOSURE_PREFIX + String(value.value)) as AgentDefId;
  }
  return value.value as AgentDefId;
}

export function decodeCoreAgentDefId(id: AgentDefId): CoreAgentDefId {
  const s = id as unknown as string;
  if (typeof s !== "string") {
    throw new Error(`agent-def-id: invalid CORE encoding: ${JSON.stringify(id)}`);
  }
  if (s.startsWith(CLOSURE_PREFIX)) {
    const n = Number(s.slice(CLOSURE_PREFIX.length));
    if (!Number.isInteger(n) || n < 0) {
      throw new Error(`agent-def-id: malformed closure id: ${JSON.stringify(s)}`);
    }
    return { kind: "closure", value: n as ClosureId };
  }
  return { kind: "qname", value: s };
}

// ─── FFI encoding / decoding ───────────────────────────────────────────────
//
// FFI side currently only handles qualified-name dispatch — sidecars have
// no concept of "closure". The wire format is the same flat string CORE
// uses for the qname case; the decoder simply rejects anything that
// looks like a closure prefix as a fast invariant check.

export type FfiAgentDefId = { kind: "qname"; value: QualifiedName };

export function encodeFfiAgentDefId(value: FfiAgentDefId): AgentDefId {
  return value.value as AgentDefId;
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
  return { kind: "qname", value: s };
}
