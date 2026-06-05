-- | Compiler-blessed source snippets that are spliced into every program
-- before the user's modules are processed.
--
-- The @primitive@ module's source carries:
--
--   1. Built-in @data@ declarations the runtime / prims need to refer to
--      by name (e.g. 'agent_metadata' returned by @get_metadata@).
--   2. @primitive@ declarations for every built-in primitive. The
--      compiler parses these like any other declaration and runs them
--      through the usual Identifier / typechecker / Lowering pipeline. The
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
      ("primitive.record", recordStdlibSource),
      ("primitive.array", arrayStdlibSource),
      ("primitive.string", stringStdlibSource),
      ("primitive.env", envStdlibSource),
      ("primitive.math", mathStdlibSource)
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
      "  requests: string,",
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
      "// File <-> string conversion.",
      "@\"Read a file's bytes back as a UTF-8 string.\"",
      "primitive file_to_string(value: file) -> string",
      "@\"Write a string's bytes to a new file (a persistent value reference). Rejects @secret@ (a credential must not be laundered into a re-readable file).\"",
      "primitive string_to_file(value: string) -> file",
      "// Internal prims — used by Lowering for pattern destructuring.",
      "// Not intended for direct user invocation but must be declared",
      "// so Lowering can resolve their BlockId.",
      "primitive tuple_get(tuple: unknown, index: integer) -> unknown",
      "primitive get_field(object: unknown, field: string) -> unknown",
      "",
      "// Metadata.",
      "@\"Return the AI metadata of any callable value.\"",
      "primitive get_metadata(value: agent) -> agent_metadata",
      "",
      "// Dynamic dispatch. `call_agent` lets you invoke a callable whose",
      "// identity is only known at runtime — a name string and an args",
      "// record — and validates the args against the target's declared",
      "// input schema. The name is the same callable handle a value carries /",
      "// `get_metadata` returns in its `id`: a fully qualified agent name",
      "// (`module.agent`) or a closure ref (`closureref:<id>`). The result",
      "// is typed `unknown` because the static type of the dispatched",
      "// callable can't be known here.",
      "@\"Raised by @call_agent@ when the name fails to resolve to a known callable, or the supplied args fail the target's input schema. Handle via @request call_agent_error(message) { ... }@.\"",
      "request call_agent_error(message: string) -> never",
      "@\"Dynamically invoke a callable by name. @name@ is the callable handle from @get_metadata@'s @id@: a qualified agent name (@module.agent@) or a closure ref (@closureref:<id>@); @args@ is a record matching the target's parameter list. Raises @call_agent_error@ on unknown names or schema-invalid args.\"",
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
      "// by the project's runtime (Postgres in `katari-api-server`). The lookup",
      "// functions live in the `primitive.env` sub-module (called as `env.get` /",
      "// `env.get_secret` / `env.set`); the `env_not_found` request stays flat in",
      "// the root module so handlers `request env_not_found(env_key) { ... }`",
      "// stay unqualified.",
      "@\"Raised when a requested env key is not present in the store. Handle to provide a default; if uncaught the snapshot transitions to the `error` state.\"",
      "request env_not_found(env_key: string) -> never",
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

-- | The @primitive.array@ sub-module source. Users call these as
-- @array.get(...)@, @array.append(...)@, etc. The growing / transforming
-- functions carry the @array_shape@ rule so the element type @T@ flows
-- through (e.g. @array.append(array[string], string) -> array[string]@).
arrayStdlibSource :: Text
arrayStdlibSource =
  Text.unlines
    [ "@\"Retrieve the element at @index@ (0-based). Raises out-of-bounds as a `throw`.\"",
      "primitive get(array: array[unknown], index: integer) -> unknown using array_get",
      "@\"Number of elements in the array.\"",
      "primitive length(array: array[unknown]) -> integer",
      "@\"The empty array. Its element type is `never` (the empty array has no elements), which is a subtype of every `array[T]`, so it can seed a typed accumulator: `var history = array.empty()` grown with `array.append`.\"",
      "primitive empty() -> array[never]",
      "@\"A single-element array carrying @value@.\"",
      "primitive of(value: unknown) -> array[unknown] using array_shape",
      "@\"Append @value@ to the end, returning a fresh array (arrays are immutable).\"",
      "primitive append(array: array[unknown], value: unknown) -> array[unknown] using array_shape",
      "@\"Concatenate two arrays into a fresh array.\"",
      "primitive concat(lhs: array[unknown], rhs: array[unknown]) -> array[unknown] using array_shape",
      "@\"The sub-array from @start@ (inclusive) to @end@ (exclusive), 0-based.\"",
      "primitive slice(array: array[unknown], start: integer, end: integer) -> array[unknown] using array_shape",
      "@\"The array reversed.\"",
      "primitive reverse(array: array[unknown]) -> array[unknown] using array_shape",
      "@\"True if @value@ is structurally equal to some element.\"",
      "primitive contains(array: array[unknown], value: unknown) -> boolean",
      "@\"Index of the first element structurally equal to @value@, or -1 if absent.\"",
      "primitive index_of(array: array[unknown], value: unknown) -> integer"
    ]

-- | The @primitive.string@ sub-module source. Users call these as
-- @string.length(...)@, @string.slice(...)@, etc. Offsets / lengths are
-- counted in Unicode code points (the result of decoding the UTF-8 text),
-- not UTF-16 code units. Every argument is typed @string@, so a @secret@
-- cannot be measured or sliced (its length / contents stay disjoint).
stringStdlibSource :: Text
stringStdlibSource =
  Text.unlines
    [ "@\"Number of Unicode code points in the string.\"",
      "primitive length(value: string) -> integer",
      "@\"The sub-string from @start@ (inclusive) to @end@ (exclusive), counted in code points.\"",
      "primitive slice(value: string, start: integer, end: integer) -> string",
      "@\"True if @substring@ occurs anywhere in @value@.\"",
      "primitive contains(value: string, substring: string) -> boolean",
      "@\"True if @value@ begins with @prefix@.\"",
      "primitive starts_with(value: string, prefix: string) -> boolean",
      "@\"True if @value@ ends with @suffix@.\"",
      "primitive ends_with(value: string, suffix: string) -> boolean",
      "@\"Code-point index of the first occurrence of @substring@, or -1 if absent.\"",
      "primitive index_of(value: string, substring: string) -> integer",
      "@\"Upper-case the string.\"",
      "primitive upper(value: string) -> string",
      "@\"Lower-case the string.\"",
      "primitive lower(value: string) -> string",
      "@\"Strip leading and trailing whitespace.\"",
      "primitive trim(value: string) -> string",
      "@\"Split on every occurrence of @separator@. An empty separator splits into code points.\"",
      "primitive split(value: string, separator: string) -> array[string]",
      "@\"Join the parts with @separator@ between them.\"",
      "primitive join(parts: array[string], separator: string) -> string",
      "@\"Replace every occurrence of @pattern@ with @replacement@ (literal, not a regex).\"",
      "primitive replace(value: string, pattern: string, replacement: string) -> string"
    ]

-- | The @primitive.env@ sub-module source. Users call these as
-- @env.get(...)@ / @env.get_secret(...)@ / @env.set(...)@. They are
-- externals routed to the runtime's ENV module; the @env_not_found@
-- request they raise lives flat in the root @primitive@ module.
envStdlibSource :: Text
envStdlibSource =
  Text.unlines
    [ "@\"Look up a non-secret env entry by key. Raises `env_not_found` if the key is missing.\"",
      "external get(key: string) -> string with env_not_found from \"ENV:get_env\"",
      "@\"Look up a secret env entry by key. The result is the disjoint `secret` type and never leaks into `to_string` / f-strings. Raises `env_not_found` if the key is missing.\"",
      "external get_secret(key: string) -> secret with env_not_found from \"ENV:get_secret_env\"",
      "@\"Write an env entry. `is_secret = true` stores the value encrypted; reading it back requires `env.get_secret`.\"",
      "external set(key: string, value: string, is_secret: boolean) -> null from \"ENV:set_env\""
    ]

-- | The @primitive.math@ sub-module source. Users call these as
-- @math.abs(...)@, @math.min(...)@, etc. @abs@ / @min@ / @max@ preserve
-- integer-ness when their operands are integers; @floor@ / @ceil@ /
-- @round@ always narrow a number to an integer.
mathStdlibSource :: Text
mathStdlibSource =
  Text.unlines
    [ "@\"Absolute value (integer when the operand is integer).\"",
      "primitive abs(value: number) -> number using numeric_join_unary",
      "@\"The smaller of two numbers (integer when both are integers).\"",
      "primitive min(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"The larger of two numbers (integer when both are integers).\"",
      "primitive max(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Round down to the nearest integer.\"",
      "primitive floor(value: number) -> integer",
      "@\"Round up to the nearest integer.\"",
      "primitive ceil(value: number) -> integer",
      "@\"Round to the nearest integer (ties away from zero).\"",
      "primitive round(value: number) -> integer"
    ]
