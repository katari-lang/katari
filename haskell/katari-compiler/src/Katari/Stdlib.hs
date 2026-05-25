-- | Compiler-blessed source snippets that are spliced into every program
-- before the user's modules are processed.
--
-- The @prim@ module's source carries:
--
--   1. Built-in @data@ declarations the runtime / prims need to refer to
--      by name (e.g. 'agent_metadata' returned by @get_metadata@).
--   2. @prim agent@ declarations for every built-in primitive. The
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
-- spliced under. Module-name keys may overlap with prim-reserved names
-- (@prim@ / @prim.*@) — that's exactly the point of stdlib snippets.
stdlibSources :: Map Text Text
stdlibSources =
  Map.singleton "prim" primStdlibSource

-- | The set of module names occupied by 'stdlibSources'. Identifier
-- skips its K0113 \"reserved prim module\" check for these names since
-- they originate from the compiler, not the user.
stdlibModuleNames :: Set Text
stdlibModuleNames = Map.keysSet stdlibSources

-- | The full @prim@ module source. Includes the @agent_metadata@ data
-- type plus a @prim agent@ declaration for every built-in primitive
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
      "prim agent add(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Subtract two numbers.\"",
      "prim agent sub(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Multiply two numbers.\"",
      "prim agent mul(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Floor-mod two numbers.\"",
      "prim agent mod(lhs: number, rhs: number) -> number using numeric_join_binary",
      "@\"Divide two numbers (always returns number).\"",
      "prim agent div(lhs: number, rhs: number) -> number",
      "@\"Unary negate.\"",
      "prim agent neg(value: number) -> number",
      "@\"Absolute value (integer when operand is integer).\"",
      "prim agent abs(value: number) -> number using numeric_join_unary",
      "",
      "// Comparison.",
      "@\"Structural equality.\"",
      "prim agent eq(lhs: unknown, rhs: unknown) -> boolean",
      "@\"Structural inequality.\"",
      "prim agent ne(lhs: unknown, rhs: unknown) -> boolean",
      "@\"Less than.\"",
      "prim agent lt(lhs: number, rhs: number) -> boolean",
      "@\"Less or equal.\"",
      "prim agent le(lhs: number, rhs: number) -> boolean",
      "@\"Greater than.\"",
      "prim agent gt(lhs: number, rhs: number) -> boolean",
      "@\"Greater or equal.\"",
      "prim agent ge(lhs: number, rhs: number) -> boolean",
      "",
      "// Logic.",
      "@\"Logical and.\"",
      "prim agent and(lhs: boolean, rhs: boolean) -> boolean",
      "@\"Logical or.\"",
      "prim agent or(lhs: boolean, rhs: boolean) -> boolean",
      "@\"Logical not.\"",
      "prim agent not(value: boolean) -> boolean",
      "",
      "// String / pretty-print.",
      "@\"Concatenate two strings (taint-aware: if either operand is secret, the result is secret).\"",
      "prim agent concat(lhs: string, rhs: string) -> string using fstring_join",
      "@\"Return the runtime type-of-value tag as a string.\"",
      "prim agent type_of(value: unknown) -> string",
      "@\"Serialize any value to its canonical JSON string (strings get quoted; round-trips with @from_string@ when added).\"",
      "prim agent to_string(value: unknown) -> string",
      "@\"Format a value for f-string interpolation. Accepts string or secret only (taint-aware: secret yields secret); other types must be converted via @to_string@ first.\"",
      "prim agent format(value: unknown) -> string using fstring_join",
      "",
      "// Structural access.",
      "@\"Retrieve the element at @index@.\"",
      "prim agent array_get(array: unknown, index: integer) -> unknown",
      "@\"Length of an array.\"",
      "prim agent array_length(array: unknown) -> integer",
      "@\"Retrieve a tagged-value field by name.\"",
      "prim agent get_field(object: unknown, field: string) -> unknown",
      "@\"Retrieve a tuple element by positional index.\"",
      "prim agent tuple_get(tuple: unknown, index: integer) -> unknown",
      "",
      "// Metadata.",
      "@\"Return the AI metadata of any callable value.\"",
      "prim agent get_metadata(value: agent) -> agent_metadata",
      "",
      "// Errors. `throw` is the universal recoverable-error capability:",
      "// engine prim errors, FFI-handler throws, refutable pattern misses",
      "// all surface here. The typechecker special-cases it so callers",
      "// don't have to write `with throw` everywhere; handlers catch via",
      "// the usual `req throw(msg) { ... }` form inside a handle scope.",
      "@\"Raise a recoverable runtime error. Bubbles through enclosing handle scopes until a `req throw` handler catches it; if nothing catches it the snapshot transitions to the `error` state.\"",
      "req throw(msg: string) -> never",
      "",
      "// Env access. The runtime's ENV module owns a key/value store backed",
      "// by the project's runtime (Postgres in `katari-api-server`). Secret",
      "// entries are returned as the disjoint `secret` type so the type",
      "// system can prevent them from leaking into `print` / `to_string` etc.",
      "// Missing keys surface as `env_not_found` — handle it with",
      "// `req env_not_found(env_key) { ... }` to provide a fallback.",
      "@\"Raised when a requested env key is not present in the store. Handle to provide a default; if uncaught the snapshot transitions to the `error` state.\"",
      "req env_not_found(env_key: string) -> never",
      "@\"Look up a non-secret env entry by key. Raises `env_not_found` if the key is missing.\"",
      "ext agent get_env(key: string) -> string with env_not_found from \"ENV:get_env\"",
      "@\"Look up a secret env entry by key. The result is the disjoint `secret` type and never leaks into `print` / `to_string`. Raises `env_not_found` if the key is missing.\"",
      "ext agent get_secret_env(key: string) -> secret with env_not_found from \"ENV:get_secret_env\"",
      "@\"Write an env entry. `is_secret = true` stores the value encrypted; reading it back requires `get_secret_env`.\"",
      "ext agent set_env(key: string, value: string, is_secret: boolean) -> null from \"ENV:set_env\""
    ]
