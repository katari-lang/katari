// The IR contract between the Katari compiler and the runtime — the TypeScript mirror of the
// Haskell `Katari.Data.IR` (one `IRModule` per source module). This file fixes the JSON wire
// encoding the compiler must emit (its `ToJSON` instances are derived against these shapes); the
// runtime stores each `IRModule` verbatim in a content-addressed module store keyed by its content
// hash, and a snapshot references modules by hash through a name->hash manifest (see
// docs/2026-06-19-per-module-snapshot.md).
//
// Encoding conventions (co-designed with the runtime):
//   - Sum types are tagged with a `kind` discriminator.
//   - `BlockId` / `VariableId` / `GenericId` are integers (Haskell `Word32` / `Int`).
//   - Maps keyed by `BlockId` serialise as JSON objects with stringified-number keys; the
//     `QualifiedName`-keyed `entries` map uses the rendered "module.name" string as the key.

import type { Json } from "./json";

/** Qualified name, rendered as "path.to.module.name" (Haskell `Katari.Data.QualifiedName`). */
export type QualifiedName = string & { readonly __brand: unique symbol };

export function createAgentName(name: string): QualifiedName {
  return name as QualifiedName;
}

/** Block identifier, unique within an `IRModule` (Haskell `BlockId`, a `Word32`). */
export type BlockId = number;

/** IR-level variable, one per value slot within a block's scope (Haskell `VariableId`). */
export type VariableId = number;

/** A generic parameter slot (Haskell `Katari.Data.Id.GenericId`, an `Int`). */
export type GenericId = number;

// ─── Module ──────────────────────────────────────────────────────────────────────────────────

export type Metadata = {
  /** Bumped on backward-incompatible changes to the IR JSON shape, so the runtime can reject stale bundles.
   *  Version 2 added the `drop` operation and version 3 the `defer` operation, each of which an
   *  older runtime cannot execute. */
  schemaVersion: number;
};

/** One module's lowered output. Callables resolve by `QualifiedName` through `entries`. */
export type IRModule = {
  metadata: Metadata;
  /** Every block, wrapped in a `BlockInformation` that carries the parameters its scope is seeded with. */
  blocks: Record<number, BlockInformation>;
  /** Top-level callable name -> its agent `BlockId`, for resolving a delegate `CalleeName` at run time. */
  entries: Record<QualifiedName, BlockId>;
  /** Debug-only block names (pretty printer / traces); ignored on the hot path. */
  names: Record<number, string>;
};

// ─── Block wrapper ─────────────────────────────────────────────────────────────────────────────

/**
 * A block plus the parameter map the runtime uses to seed its thread's scope on entry.
 *
 * `parameters` is name -> the `VariableId` in this block's scope that receives the passed-in value.
 * Used by:
 *   - Agent body: `parameter` -> the agent's argument value.
 *   - For body Sequence: `iterator` -> current element; `state_0`, `state_1`, ... -> current states.
 *   - For then-clause body: `result` -> the mapped output array; `state_0`, ... -> final states.
 *   - Handler body: `parameter` -> the request argument; `state_0`, ... -> current states.
 *   - Handle then-clause body: `result` -> body result; `state_0`, ... -> final states.
 *
 * Structural-node blocks themselves (Match / For / Handle / Parallel) are IR constants and carry
 * no parameters; the entries above name their body / handler / then-clause Sequence blocks.
 */
export type BlockInformation = {
  block: Block;
  parameters: Record<string, VariableId>;
};

// ─── Blocks (each runs as its own thread) ──────────────────────────────────────────────────────

/**
 * A schedulable unit. `agent` is the sole value-addressable wrapper (it carries a schema); every
 * other block is reached only as an agent's body or as a structural node, and carries no schema.
 */
export type Block =
  | AgentBlock
  | SequenceBlock
  | PrimitiveBlock
  | ConstructBlock
  | RequestBlock
  | ExternalBlock
  | MatchBlock
  | ForBlock
  | ForeverBlock
  | HandleBlock
  | ParallelBlock;

/**
 * The single value-addressable callable. The argument binds via the body's `BlockInformation.parameters`
 * (`parameter`). Whether a call commits is the body's property (derived at run time), not stored here.
 *
 * `defaults` are the values for omittable (optional) parameters, keyed by parameter name: before running
 * the body, the runtime fills any parameter absent from the argument record with its default. This is the
 * single defaults mechanism for every callable — user agents, data constructors, requests, externals and
 * primitives all carry their defaults here (the leaf bodies no longer do).
 */
export type AgentBlock = {
  kind: "agent";
  body: BlockId;
  schema: SchemaInfo;
  /** The declaration's `@"..."` annotation (empty when undocumented; absent in pre-description IR).
   *  Surfaced by `get_metadata` so an AI sees the callable's description next to its schema. */
  description?: string;
  defaults: Record<string, Literal>;
};

/** An agent / structural body: a list of operations plus the variable holding its value (if any). */
export type SequenceBlock = {
  kind: "sequence";
  operations: Operation[];
  result: VariableId | null;
};

/**
 * Leaf body — a built-in primitive (resolved against the runtime's prim registry by `name`).
 * `input` is the in-scope variable holding the argument (seeded by the wrapping agent via
 * `BlockInformation.parameters`); the wrapping `AgentBlock.defaults` are already filled.
 */
export type PrimitiveBlock = {
  kind: "primitive";
  name: string;
  input: VariableId;
};

/** Leaf body — a data constructor: build the tagged value of `name` from `input`. */
export type ConstructBlock = {
  kind: "construct";
  name: QualifiedName;
  input: VariableId;
};

/** Leaf body — a request: raise `name` as an escalation, carrying `input`. */
export type RequestBlock = {
  kind: "request";
  name: QualifiedName;
  input: VariableId;
};

/** The reactors an `external ... from "name"` clause may route a call to. This mirrors the compiler's
 *  `externalReactorNames` (Katari.Typechecker.Check): the checker rejects any other name at compile time
 *  (K3018) and lowering stamps `"ffi"` when the clause is absent, so IR can only ever carry these — which
 *  is why the runtime copies the marker without a fallback. Adding a reactor is one edit here plus one in
 *  the compiler's list. */
export type ExternalReactorName = "ffi" | "http" | "webhook" | "mcp" | "time" | "oauth";

/** Leaf body — an external agent dispatched by the external handler via `key`, with `input` as the argument.
 *  `reactor` names the reactor the call routes to (`"ffi"` — the sidecar — by default, or e.g. `"http"` for
 *  the built-in http reactor), from the declaration's `from "name"` clause. */
export type ExternalBlock = {
  kind: "external";
  key: string;
  input: VariableId;
  reactor: ExternalReactorName;
};

/** `match subject { ... }`: try `arms` in order, run the first match's body (or `fallback`). */
export type MatchBlock = {
  kind: "match";
  subject: VariableId;
  arms: MatchArm[];
  fallback: BlockId | null;
};

export type MatchArm = { pattern: Pattern; body: BlockId };

/**
 * `[par] for (pattern in source; var s = init) { body } [then (p) { ... }]`. Each iteration's
 * `next` value is collected, in source order, into the mapped output array. `source` and
 * `initialStates` are in the caller's scope; the runtime seeds the body's `iterator` / `state_N`
 * parameters from them per iteration.
 */
export type ForBlock = {
  kind: "for";
  parallel: boolean;
  /** The source array to iterate, in the caller's scope. */
  source: VariableId;
  /** Initial state values in the caller's scope, in order; the Nth seeds the body's `state_N`. Empty when parallel. */
  initialStates: VariableId[];
  body: BlockId;
  thenClause: ThenClause | null;
};

/**
 * `forever [(var s = init, ...)] { body }`: each time `body` completes, run it again — one iteration at a
 * time, its value discarded (nothing is collected, unlike `for`, so iteration count never grows the loop's
 * state). `initialStates` are in the caller's scope; the Nth seeds the body's `state_N` parameter, carried
 * across iterations and advanced by a `next … with (…)` (empty for a stateless `forever { … }`). The block
 * completes only when the body `break`s (unwinding an exit to it with the loop's result value); otherwise
 * it ends only by cancellation or an ask unwinding past it.
 */
export type ForeverBlock = {
  kind: "forever";
  initialStates: VariableId[];
  body: BlockId;
};

/**
 * A `handle` scope: run `body`, dispatch escalations to `handlers`, run `thenClause` on completion.
 * `initialStates` are in the caller's scope; they seed the body / handler `state_N` parameters.
 */
export type HandleBlock = {
  kind: "handle";
  parallel: boolean;
  initialStates: VariableId[];
  body: BlockId;
  handlers: Handler[];
  thenClause: ThenClause | null;
};

/**
 * One request handler. On a matching escalation the runtime seeds the handler body's scope (the
 * request argument as `parameter`, the current states as `state_N`; see `BlockInformation`) and runs `body`.
 */
export type Handler = {
  request: QualifiedName;
  body: BlockId;
};

/**
 * A `then (pattern) { body }` clause. The produced value (the for-mapping array / the handle body's
 * result) is seeded as the clause body's `result` parameter, alongside the final `state_N`s.
 */
export type ThenClause = {
  body: BlockId;
};

/** `par [e1, ...]`: each element is its own block, evaluated concurrently, results collected in order. */
export type ParallelBlock = { kind: "parallel"; elements: BlockId[] };

// ─── Operations (each runs within the enclosing block's thread) ────────────────────────────────

export type Operation =
  | CallOperation
  | DelegateOperation
  | LoadLiteralOperation
  | LoadAgentOperation
  | MakeClosureOperation
  | MakeRecordOperation
  | MakeTupleOperation
  | GetFieldOperation
  | BindPatternOperation
  | ApplyGenericsOperation
  | ExitOperation
  | ContinueOperation
  | DropOperation
  | DeferOperation;

/** Enter a local structural node (`match` / `for` / `handle` / `par`) in the current scope. */
export type CallOperation = { kind: "call"; target: BlockId; output: VariableId | null };

/**
 * Invoke an agent block with the single argument value. Target is a `QualifiedName` (resolved via
 * `entries`) or a runtime value (a dynamically-supplied agent / closure). Always summons a child
 * instance — named or closure alike (the in-shard closure call is not a special case).
 */
export type DelegateOperation = {
  kind: "delegate";
  target: CalleeReference;
  argument: VariableId;
  output: VariableId | null;
  /** The call site's generic instantiation (explicit or inferred) as runtime schemas, keyed by the
   *  callee's declared parameter names — same encoding as `ApplyGenericsOperation.generics`. Merged at
   *  run time with the substitution the callee VALUE carries; omitted for a non-generic callee. */
  generics?: Array<[string, GenericArgumentSchema]>;
};

export type LoadLiteralOperation = { kind: "loadLiteral"; output: VariableId; value: Literal };

/**
 * Materialize a top-level callable as a first-class agent value by `QualifiedName` (resolved via
 * `entries`). The counterpart of `makeClosure` for a named top-level agent / data-constructor /
 * request / external / primitive used as a value; `makeClosure` stays for a local agent (closure).
 */
export type LoadAgentOperation = { kind: "loadAgent"; output: VariableId; name: QualifiedName };

/** Make a closure value capturing the current scope; it resolves to the given agent block. */
export type MakeClosureOperation = { kind: "makeClosure"; output: VariableId; agent: BlockId };

/** Build a record value from in-scope vars (a named-args record / a record literal). */
export type MakeRecordOperation = {
  kind: "makeRecord";
  entries: Array<[string, VariableId]>;
  output: VariableId;
};

/** Build a sequential array value from in-scope vars. (`par [...]` uses a `ParallelBlock` instead.) */
export type MakeTupleOperation = { kind: "makeTuple"; elements: VariableId[]; output: VariableId };

/** Read one field of a record value (`obj.field` / a parameter binding); `null` when absent. */
export type GetFieldOperation = {
  kind: "getField";
  source: VariableId;
  field: string;
  output: VariableId;
};

/** Irrefutably destructure a value (a `let` pattern; exhaustiveness guaranteed by the checker). */
export type BindPatternOperation = { kind: "bindPattern"; source: VariableId; pattern: Pattern };

/** Attach a generic substitution to a callable value (for `get_metadata` schema specialisation). */
export type ApplyGenericsOperation = {
  kind: "applyGenerics";
  source: VariableId;
  generics: Array<[string, GenericArgumentSchema]>;
  output: VariableId;
};

/** A non-local exit (return / break / for-break). `target` is the enclosing block it unwinds to. */
export type ExitOperation = { kind: "exit"; target: BlockId; value: VariableId };

/** A non-local continue (next / for-next). `target` is the enclosing handle / for it resumes. */
export type ContinueOperation = {
  kind: "continue";
  target: BlockId;
  value: VariableId | null;
  /** `with (name = e, ...)` state updates: (state var in the target's scope, new-value var here). */
  modifiers: Array<[VariableId, VariableId]>;
};

/**
 * Release bindings this same sequence wrote and provably never reads again (inserted by the compiler's
 * conservative post-lowering liveness pass, `Katari.Lowering.Drop`). The runtime deletes each binding
 * from the thread's LOCAL scope, shrinking the scope row persisted every turn; scope-level GC remains
 * the backstop for anything the pass could not prove dead. The list is non-empty and sorted by id.
 */
export type DropOperation = { kind: "drop"; variables: VariableId[] };

/**
 * Arm a `finally` block as a finalizer of the CURRENT INSTANCE: the runtime pushes (block, the
 * executing thread's scope) onto the instance's finalizer stack and runs the stack in reverse arming
 * order right before the instance acknowledges its terminal (a normal completion's delegateAck or a
 * cancellation's cancelAck) — never on a panic. The armed block reads the enclosing scope through the
 * ordinary parent chain, so it carries no parameters of its own.
 */
export type DeferOperation = { kind: "defer"; block: BlockId };

/** A callable-invocation target: a name (via `entries`) or a runtime value (an agent / closure). */
export type CalleeReference =
  | { kind: "name"; name: QualifiedName }
  | { kind: "value"; variable: VariableId };

// ─── Literals and patterns ─────────────────────────────────────────────────────────────────────

export type Literal =
  | { kind: "null" }
  | { kind: "boolean"; value: boolean }
  | { kind: "integer"; value: number }
  | { kind: "number"; value: number }
  | { kind: "string"; value: string };

/** A runtime match pattern. The whole nested pattern is kept (no compilation to a tag cascade). */
export type Pattern =
  | { kind: "any" }
  | { kind: "variable"; variable: VariableId }
  | { kind: "literal"; value: Literal }
  | { kind: "constructor"; name: QualifiedName; fields: Array<[string, Pattern]> }
  | { kind: "tuple"; elements: Pattern[] }
  | { kind: "record"; fields: Array<[string, Pattern]> }
  | { kind: "typeGuard"; tag: TypeTag; pattern: Pattern };

/** The runtime-checkable tag a `T(pattern)` type filter narrows on. */
export type TypeTag =
  | "null"
  | "boolean"
  | "integer"
  | "number"
  | "string"
  | "file"
  | "array"
  | "record"
  | "agent";

// ─── Schemas carried per callable ──────────────────────────────────────────────────────────────

/** The public schema of one callable: its input, output, requests, and generic-parameter bindings. */
export type SchemaInfo = {
  input: JSONSchema;
  output: JSONSchema;
  requests: RequestSchema[];
  /** This callable's generic parameters, keyed by name: each maps to the `GenericId` its references
   *  use in `input` / `output` (`$generic`) and `requests`. */
  genericBindings: Record<string, GenericId>;
};

/** One requests-schema entry: a concrete request, or a reference to an effect-generic parameter. */
export type RequestSchema =
  | { kind: "concrete"; descriptor: RequestDescriptor }
  | { kind: "generic"; generic: GenericId };

export type RequestDescriptor = { name: QualifiedName; input: JSONSchema; output: JSONSchema };

/** The schema of one generic argument supplied at an `applyGenerics` site. */
export type GenericArgumentSchema =
  | { kind: "type"; schema: JSONSchema }
  | { kind: "requests"; requests: RequestSchema[] };

/**
 * The subset of JSON Schema the compiler emits (Haskell `Katari.Data.JSONSchema`), serialised as a
 * standard JSON Schema document. All keys are optional: `{}` matches anything; `{"not": {}}` matches
 * nothing; `$generic` is the generic-reference sentinel the runtime fills at `get_metadata`.
 */
export type JSONSchema = {
  type?: "null" | "boolean" | "integer" | "number" | "string" | "array" | "object";
  const?: Json;
  /** A homogeneous array's element schema (every element matches it). */
  items?: JSONSchema;
  /** A tuple's positional element schemas (`[A, B]` -> one schema per position). */
  prefixItems?: JSONSchema[];
  properties?: Record<string, JSONSchema>;
  required?: string[];
  /** A boolean (closed/open object), or the schema every other key must match (a `record[T]` tail). */
  additionalProperties?: boolean | JSONSchema;
  anyOf?: JSONSchema[];
  not?: JSONSchema;
  $generic?: GenericId;
};
