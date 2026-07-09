// Value: the runtime's in-memory value model. Scalars and small composites are inline; large bytes
// (big strings / files) live in a content-addressed blob and are referenced by a `ref` value.
// Callable values come in two shapes — a top-level named agent (`agent`) and a `closure`
// (案2: a block + captured scope carried directly as a value, with no separate closure entity).
//
// This is also the JSON shape stored at rest: a scope's variables ride inline in its `scopes.values`
// JSON column (each holding a `Value`), a blob's bytes live in the BlobStore (S3 object key
// `{projectId}/{blobId}`), and the ref keeps only the handle + metadata.
//
// A `Value` carries an optional `private` flag (intersection on every variant). It is the single
// source of truth for "treat this value as private" — used by persistence (encrypt-at-rest), by
// transport (warn / redact on emission), and by logging (redaction). The flag is preserved across
// every operation that reproduces the value as-is.

import type { BlockId, GenericArgumentSchema, JSONSchema, QualifiedName } from "@katari-lang/types";
import type { BlobId, ScopeId, SnapshotId } from "../ids.js";

/** The privacy SSoT: when true, the value is treated as private at rest, in transit, and in logs. */
export type PrivacyMarker = { private?: boolean };

export type Value = (
  | { kind: "null" }
  | { kind: "boolean"; value: boolean }
  | { kind: "integer"; value: number }
  | { kind: "number"; value: number }
  /** An inline (small) string. Large strings are promoted to a blob `ref` at persist (R5/CORE promotion). */
  | { kind: "string"; value: string }
  /**
   * A record value. A bare object literal carries no `ctor`; a `data` value carries its constructor's
   * qualified name there (a tagged value). At the JSON boundary the tag rides under the reserved
   * `$constructor` discriminator key (compiler `Katari.Schema.constructorDiscriminatorKey`); internally
   * it is kept out-of-band so `obj.field` and width subtyping (`data <: object`) ignore it.
   */
  | { kind: "record"; fields: Record<string, Value>; ctor?: QualifiedName }
  | { kind: "array"; elements: Value[] }
  | BlobRefValue
  | ClosureValue
  | AgentValue
  | ToolValue
) &
  PrivacyMarker;

/** The semantic kind of the bytes a blob holds. Distinguishes content compare / display. */
export type SemanticKind = "string" | "file";

/** A reference to a content-addressed blob (the second axis of the value model alongside the blob itself). */
export type BlobRefValue = {
  kind: "ref";
  semanticKind: SemanticKind;
  blobId: BlobId;
  /** Content hash — used for `string == string` content comparison without fetching the bytes. */
  hash: string;
  size: number;
  contentType?: string;
};

/** A generic substitution attached to a callable value (from a `foo[T]` instantiation). */
export type GenericSubstitution = Record<string, GenericArgumentSchema>;

/**
 * A closure carried as a value (案2): the body block + the captured scope, referenced directly.
 * Calling it is an `OperationDelegate` like any agent call (it summons a child instance whose body
 * scope chains to `scopeId` in the CORE-global scope store). No separate `closures` entity exists;
 * the captured `Scope` is the only owned resource, and ascent follows `scopeId` out of escaping values.
 */
export type ClosureValue = {
  kind: "closure";
  blockId: BlockId;
  scopeId: ScopeId;
  /** The snapshot whose IR `blockId` lives in (so the closure resolves even if it escapes). */
  snapshot: SnapshotId;
  /** The module `blockId` is local to (block ids are module-local; needed to resolve an escaped closure). */
  module: string;
  generics?: GenericSubstitution;
};

/** A top-level named callable carried as a value (`agentLiteral`): the delegate target `(name, snapshot)`. */
export type AgentValue = {
  kind: "agent";
  name: QualifiedName;
  snapshot: SnapshotId;
  generics?: GenericSubstitution;
};

/**
 * A reactor-backed agent: the value-level mirror of an `external agent` declaration, minted only by
 * the runtime (an MCP server's tool — `prelude.mcp.tools` mints one per server tool). Where a named
 * agent references compiled code and a closure references a block + captured scope, a tool references
 * a REACTOR (`reactor` + the reactor-scoped `name`) + an opaque `context` the reactor needs to
 * execute (an MCP tool carries its server descriptor — url + headers). `get_metadata` reads the
 * attached runtime-decided signature; a call validates its argument against `inputSchema` where the
 * dispatch is emitted (mismatch = `reflection.call_error`), then delegates DIRECTLY to the reactor —
 * the argument passes through verbatim, the context rides the delegate target out-of-band (exactly
 * like a closure's captured scope).
 */
export type ToolValue = {
  kind: "tool";
  /** The reactor that executes a call — the tool's implementation home (`"mcp"` today). */
  reactor: string;
  /** The reactor-scoped dispatch key AND the public metadata name (an MCP server's tool name). */
  name: string;
  description: string;
  /** Opaque, reactor-owned execution context (an MCP tool: `{url, headers}`, headers private —
   *  the privacy marker rides, so persistence seals it and user-facing boundaries redact it). */
  context: Value;
  /** The snapshot the tool was minted under (rides the external delegate target; informational). */
  snapshot: SnapshotId;
  inputSchema: JSONSchema;
  /** The provider-declared output schema, when it declares one (MCP `outputSchema`) — metadata for
   *  `get_metadata`; results are not validated against it. Absent means unknown. */
  outputSchema?: JSONSchema;
};
