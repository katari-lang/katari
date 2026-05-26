-- | Compiler-blessed source snippets that are spliced into every program
-- before the user's modules are processed.
--
-- The @primitive@ module's source carries:
--
--   1. Built-in @data@ declarations the runtime / prims need to refer to
--      by name (e.g. 'agent_metadata' returned by @get_metadata@).
--   2. @primitive@ declarations for every built-in primitive. The
--      compiler parses these like any other declaration and runs them
--      through the usual Identifier / CG / Zonk / Lowering pipeline. The
--      runtime executes a hardcoded implementation keyed on the prim's
--      bare name (see @katari-runtime/src/engine/prim.ts@).
--
-- All snippets are spliced under their stated module name. For @prim@
-- specifically, the Identifier-pass auto-import mechanism then propagates
-- the resulting symbols into every user module's lexical scope (so users
-- can write @add@ / @agent_metadata@ unqualified).
module Katari.Stdlib
  ( stdlibSources,
    stdlibModuleNames,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Text (Text)
import Data.Text qualified as Text

-- | All compiler-blessed sources, keyed by the module name they are
-- spliced under. Module-name keys may overlap with reserved primitive
-- names (@primitive@ / @primitive.*@) — that's exactly the point of
-- stdlib snippets.
stdlibSources :: Map Text Text
stdlibSources =
  Map.fromList
    [ ("primitive", primStdlibSource),
      ("primitive.json", jsonStdlibSource),
      ("primitive.record", recordStdlibSource)
    ]

-- | The set of module names occupied by 'stdlibSources'. Identifier
-- skips its K0113 \"reserved prim module\" check for these names since
-- they originate from the compiler, not the user.
stdlibModuleNames :: Set Text
stdlibModuleNames = Map.keysSet stdlibSources

-- | The full @prim@ module source. Includes the @agent_metadata@ data
-- type plus a @primitive@ declaration for every built-in primitive
-- the runtime ships with.
primStdlibSource :: Text
primStdlibSource =
  Text.unlines
    [ "@\"AI metadata of a callable (name / id / description / I-O schema).\"",
      "data agent_metadata(",
      "  name: string,",
      "  id: string,",
      "  description: string,",
      "  input: string,",
      "  output: string,",
      ")",
      "",
      "// Arithmetic (operand-aware: integer + integer = integer).",
      "@\"Add two numbers.\"",
      "primitive add(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Subtract two numbers.\"",
      "primitive sub(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Multiply two numbers.\"",
      "primitive mul(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Floor-mod two numbers.\"",
      "primitive mod(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Divide two numbers (always returns number).\"",
      "primitive div(lhs: number, rhs: number) -> number",
      "@\"Unary negate.\"",
      "primitive neg(value: number) -> number",
      "@\"Absolute value (integer when operand is integer).\"",
      "primitive abs(value: number) -> number using numeric_join_unary",
      "",
      "// Comparison.",
      "@\"Structural equality.\"",
      "primitive eq(lhs: unknown, rhs: unknown) -> boolean",
      "@\"Structural inequality.\"",
      "primitive ne(lhs: unknown, rhs: unknown) -> boolean",
      "@\"Less than.\"",
      "primitive lt(lhs: number, rhs: number) -> boolean",
      "@\"Less or equal.\"",
      "primitive le(lhs: number, rhs: number) -> boolean",
      "@\"Greater than.\"",
      "primitive gt(lhs: number, rhs: number) -> boolean",
      "@\"Greater or equal.\"",
      "primitive ge(lhs: number, rhs: number) -> boolean",
      "",
      "// Logic.",
      "@\"Logical and.\"",
      "primitive and(lhs: boolean, rhs: boolean) -> boolean",
      "@\"Logical or.\"",
      "primitive or(lhs: boolean, rhs: boolean) -> boolean",
      "@\"Logical not.\"",
      "primitive not(value: boolean) -> boolean",
      "",
      "// String / pretty-print.",
      "@\"Concatenate two strings (taint-aware: if either operand is secret, the result is secret).\"",
      "primitive concat(lhs: string, rhs: string) -> string using fstring_join",
      "@\"Return the runtime type-of-value tag as a string.\"",
      "primitive type_of(value: unknown) -> string",
      "@\"Serialize any value to its canonical wire-format string (Plan D — strings get quoted, tagged values get their @$constructor@ discriminator). Inverse: @from_string@.\"",
      "primitive to_string(value: unknown) -> string",
      "@\"Raised by @from_string@ when the input cannot be decoded as a canonical wire-format value (invalid JSON, illegal discriminator combinations, etc.). Handle via @request from_string_error(message) { ... }@.\"",
      "request from_string_error(message: string) -> never",
      "@\"Parse a wire-format string (produced by @to_string@) back into a value. Raises @from_string_error@ on malformed input.\"",
      "primitive from_string(text: string) -> unknown with from_string_error",
      "@\"Format a value for f-string interpolation. Accepts string or secret only (taint-aware: secret yields secret); other types must be converted via @to_string@ first.\"",
      "primitive format(value: unknown) -> string using fstring_join",
      "",
      "// Structural access.",
      "@\"Retrieve the element at @index@.\"",
      "primitive array_get(array: unknown, index: integer) -> unknown",
      "@\"Length of an array.\"",
      "primitive array_length(array: unknown) -> integer",
      "@\"Retrieve a tagged-value field by name.\"",
      "primitive get_field(object: unknown, field: string) -> unknown",
      "@\"Retrieve a tuple element by positional index.\"",
      "primitive tuple_get(tuple: unknown, index: integer) -> unknown",
      "",
      "// Metadata.",
      "@\"Return the AI metadata of any callable value.\"",
      "primitive get_metadata(value: agent) -> agent_metadata",
      "",
      "// Dynamic dispatch. `call_agent` lets you invoke a callable whose",
      "// identity is only known at runtime — a name string and an args",
      "// record — and validates the args against the target's declared",
      "// input schema. Names are either a fully qualified agent name",
      "// (`module.agent`) or a closure stamp (`closure:<id>`). The result",
      "// is typed `unknown` because the static type of the dispatched",
      "// callable can't be known here.",
      "@\"Raised by @call_agent@ when the name fails to resolve to a known callable, or the supplied args fail the target's input schema. Handle via @request call_agent_error(message) { ... }@.\"",
      "request call_agent_error(message: string) -> never",
      "@\"Dynamically invoke a callable by name. @name@ is either a qualified agent name (@module.agent@) or a closure stamp (@closure:<id>@); @args@ is a record matching the target's parameter list. Raises @call_agent_error@ on unknown names or schema-invalid args.\"",
      "primitive call_agent(name: string, args: record[unknown]) -> unknown with call_agent_error",
      "",
      "// Errors. `throw` is the universal recoverable-error capability:",
      "// engine prim errors, FFI-handler throws, refutable pattern misses",
      "// all surface here. The typechecker special-cases it so callers",
      "// don't have to write `with throw` everywhere; handlers catch via",
      "// the usual `request throw(msg) { ... }` form inside a handle scope.",
      "@\"Raise a recoverable runtime error. Bubbles through enclosing handle scopes until a `request throw` handler catches it; if nothing catches it the snapshot transitions to the `error` state.\"",
      "request throw(msg: string) -> never",
      "",
      "// Env access. The runtime's ENV module owns a key/value store backed",
      "// by the project's runtime (Postgres in `katari-api-server`). Secret",
      "// entries are returned as the disjoint `secret` type so the type",
      "// system can prevent them from leaking into `print` / `to_string` etc.",
      "// Missing keys surface as `env_not_found` — handle it with",
      "// `request env_not_found(env_key) { ... }` to provide a fallback.",
      "@\"Raised when a requested env key is not present in the store. Handle to provide a default; if uncaught the snapshot transitions to the `error` state.\"",
      "request env_not_found(env_key: string) -> never",
      "@\"Look up a non-secret env entry by key. Raises `env_not_found` if the key is missing.\"",
      "external get_env(key: string) -> string with env_not_found from \"ENV:get_env\"",
      "@\"Look up a secret env entry by key. The result is the disjoint `secret` type and never leaks into `print` / `to_string`. Raises `env_not_found` if the key is missing.\"",
      "external get_secret_env(key: string) -> secret with env_not_found from \"ENV:get_secret_env\"",
      "@\"Write an env entry. `is_secret = true` stores the value encrypted; reading it back requires `get_secret_env`.\"",
      "external set_env(key: string, value: string, is_secret: boolean) -> null from \"ENV:set_env\"",
      "",
      "// JSON data model. `json` is the union of the 7 RFC-8259 JSON value",
      "// shapes; `primitive.json.parse` and `.stringify` exchange it across",
      "// the wire. Constructors stay flat in the root `primitive` module",
      "// (auto-injected) so users can write `case json_array(items = xs) =>`",
      "// without qualification; the parse / stringify functions live in the",
      "// `primitive.json` sub-module and are called as `json.parse(...)`.",
      "@\"JSON null. The unit-shaped variant of the `json` union.\"",
      "data json_null()",
      "@\"JSON boolean.\"",
      "data json_boolean(value: boolean)",
      "@\"JSON integral number. Distinct from `json_number` so that round-trips through `parse` -> `stringify` preserve integer-vs-fractional form.\"",
      "data json_integer(value: integer)",
      "@\"JSON non-integral number.\"",
      "data json_number(value: number)",
      "@\"JSON string.\"",
      "data json_string(value: string)",
      "@\"JSON array of further `json` values.\"",
      "data json_array(items: array[json])",
      "@\"JSON object: a record (homogeneous string-keyed map) of further `json` values.\"",
      "data json_object(entries: record[json])",
      "// The standard JSON value union. Recursive via `json_array` /",
      "// `json_object`; pattern-match on the seven constructors to discriminate.",
      "type json = json_null | json_boolean | json_integer | json_number | json_string | json_array | json_object",
      "@\"Raised by `json.parse` when the input text is not valid JSON. Handle via `request json_parse_error(message) { ... }`.\"",
      "request json_parse_error(message: string) -> never"
    ]

-- | The @primitive.json@ sub-module source. Exposes JSON parse /
-- stringify, accessed by users as @json.parse(...)@ / @json.stringify(...)@.
-- The @json@ data union and the @json_parse_error@ request live in the
-- root @primitive@ module (auto-injected as flat names) so that
-- match-arm constructor patterns stay unqualified.
jsonStdlibSource :: Text
jsonStdlibSource =
  Text.unlines
    [ "@\"Parse a JSON-encoded string into a `json` value. Raises `json_parse_error` on malformed input.\"",
      "primitive parse(text: string) -> json with json_parse_error",
      "@\"Serialize a `json` value to canonical JSON text. The static type rules out closures / secrets / arbitrary tagged values, so this primitive is total (no runtime error path).\"",
      "primitive stringify(value: json) -> string"
    ]

-- | The @primitive.record@ sub-module source. Users call these as
-- @record.empty()@, @record.get(...)@, etc. The flat @record[V]@ type
-- name is unaffected — it's a type-position keyword recognised by the
-- parser independent of the value-namespace module alias.
recordStdlibSource :: Text
recordStdlibSource =
  Text.unlines
    [ "@\"Construct an empty record.\"",
      "primitive empty() -> record[unknown]",
      "@\"Retrieve a record entry by key. Returns null when the key is absent.\"",
      "primitive get(record: record[unknown], key: string) -> unknown",
      "@\"Insert or replace an entry, returning a fresh record (records are immutable).\"",
      "primitive set(record: record[unknown], key: string, value: unknown) -> record[unknown]",
      "@\"Remove an entry by key. Returns the record unchanged when the key is absent.\"",
      "primitive remove(record: record[unknown], key: string) -> record[unknown]",
      "@\"List the keys present in the record (insertion order is not guaranteed).\"",
      "primitive keys(record: record[unknown]) -> array[string]",
      "@\"True if the record carries an entry under the given key.\"",
      "primitive has(record: record[unknown], key: string) -> boolean",
      "@\"Number of entries in the record.\"",
      "primitive size(record: record[unknown]) -> integer"
    ]
