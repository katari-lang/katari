// The IR contract between the Katari compiler and the runtime — the TypeScript mirror of the
// Haskell `Katari.Data.IR` (one `IRModule` per source module). This file fixes the JSON wire
// encoding the compiler must emit (its `ToJSON` instances are derived against these shapes); the
// runtime stores an `IRModule` verbatim as one structured blob (`snapshots.modules`) and reads it.
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
  /** Bumped on backward-incompatible changes to the IR JSON shape, so the runtime can reject stale bundles. */
  schemaVersion: number;
};

/** One module's lowered output. Callables resolve by `QualifiedName` through `entries`. */
export type IRModule = {
  metadata: Metadata;
  /** Every block (an agent wrapper, an agent body, a leaf body, or a structural node), keyed by `BlockId`. */
  blocks: Record<number, Block>;
  /** The schema of every agent block; keyed by `BlockId`. Leaf bodies and structural nodes have none. */
  schemas: Record<number, SchemaInfo>;
  /** Top-level callable name -> its agent `BlockId`, for resolving a delegate `CalleeName` at run time. */
  entries: Record<QualifiedName, BlockId>;
  /** Debug-only block names (pretty printer / traces); ignored on the hot path. */
  names: Record<number, string>;
};

// ─── Blocks (each runs as its own thread) ──────────────────────────────────────────────────────

/**
 * A schedulable unit. `agent` is the sole value-addressable wrapper (it carries the calling
 * convention and a schema); every other block is reached only as an agent's body or as a structural
 * node, and carries no schema.
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
  | HandleBlock
  | ParallelBlock;

/**
 * The single value-addressable callable. The incoming argument binds to `parameter` in a fresh
 * scope (a `return` boundary); omitted optional fields are filled from `defaults`; then `body` runs.
 * `defaults` carries the `?=` defaults of a non-pattern parameter list (a `data` / `request` /
 * `external` / `primitive` callable, whose parameters are plain `label: type ?= default` signatures);
 * a user `agent`'s parameters are patterns (`label => pattern`, with `x ?= v` sugar for `x => x ?= v`),
 * so its defaults live in those patterns (the `default` pattern variant) and `defaults` is empty.
 * Whether a call commits is the body's property (derived at run time), not stored here.
 */
export type AgentBlock = {
  kind: "agent";
  parameter: VariableId | null;
  defaults: Record<string, Literal>;
  body: BlockId;
};

/** An agent / structural body: a list of operations plus the variable holding its value (if any). */
export type SequenceBlock = {
  kind: "sequence";
  operations: Operation[];
  result: VariableId | null;
};

/** Leaf body — a built-in primitive (resolved against the runtime's prim registry by `name`). */
export type PrimitiveBlock = { kind: "primitive"; name: string };

/** Leaf body — a data constructor: build the tagged value of `name` from the argument. */
export type ConstructBlock = { kind: "construct"; name: QualifiedName };

/** Leaf body — a request: raise `name` as an escalation to the enclosing handler. */
export type RequestBlock = { kind: "request"; name: QualifiedName };

/** Leaf body — an external agent dispatched by the external handler via the opaque `key`. */
export type ExternalBlock = { kind: "external"; key: string };

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
 * `next` value is collected, in source order, into the mapped output array.
 */
export type ForBlock = {
  kind: "for";
  parallel: boolean;
  /** (element var bound in the body scope, source-array var in the caller scope), one per iterator. */
  iterators: Array<[VariableId, VariableId]>;
  /** (state var in the body scope, initial-value var in the caller scope). Empty when parallel. */
  states: Array<[VariableId, VariableId]>;
  body: BlockId;
  thenClause: ThenClause | null;
};

/** A `handle` scope: run `body`, dispatch escalations to `handlers`, run `thenClause` on completion. */
export type HandleBlock = {
  kind: "handle";
  parallel: boolean;
  states: Array<[VariableId, VariableId]>;
  body: BlockId;
  handlers: Handler[];
  thenClause: ThenClause | null;
};

/** One request handler. On a matching escalation the request argument binds to `parameter`. */
export type Handler = {
  request: QualifiedName;
  parameter: VariableId | null;
  body: BlockId;
};

/** A `then (pattern) { body }` clause: `parameter` receives the produced value. */
export type ThenClause = {
  parameter: VariableId | null;
  body: BlockId;
};

/** `par [e1, ...]`: each element is its own block, evaluated concurrently, results collected in order. */
export type ParallelBlock = { kind: "parallel"; elements: BlockId[] };

// ─── Operations (each runs within the enclosing block's thread) ────────────────────────────────

export type Operation =
  | CallOperation
  | DelegateOperation
  | LoadLiteralOperation
  | MakeClosureOperation
  | MakeRecordOperation
  | MakeTupleOperation
  | GetFieldOperation
  | BindPatternOperation
  | ApplyGenericsOperation
  | ExitOperation
  | ContinueOperation;

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
};

export type LoadLiteralOperation = { kind: "loadLiteral"; output: VariableId; value: Literal };

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
  | { kind: "typeGuard"; tag: TypeTag; pattern: Pattern }
  /** A `?=` default: when the matched value is absent/null, substitute `value`, then match `pattern`. */
  | { kind: "default"; value: Literal; pattern: Pattern };

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
  /** This callable's generic parameters, in declaration order: each name paired with the `GenericId`
   *  its references use in `input` / `output` (`$generic`) and `requests`. The bridge from a
   *  name-keyed application onto the id-keyed template. */
  genericBindings: Array<[string, GenericId]>;
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
  items?: JSONSchema;
  properties?: Record<string, JSONSchema>;
  required?: string[];
  /** A boolean (closed/open object), or the schema every other key must match (a `record[T]` tail). */
  additionalProperties?: boolean | JSONSchema;
  anyOf?: JSONSchema[];
  not?: JSONSchema;
  $generic?: GenericId;
};
