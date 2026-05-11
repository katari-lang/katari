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
      "@\"Concatenate two strings.\"",
      "prim agent concat(lhs: string, rhs: string) -> string",
      "@\"Return the runtime type-of-value tag as a string.\"",
      "prim agent type_of(value: unknown) -> string",
      "@\"Serialize any value to its canonical JSON string (strings get quoted; round-trips with @from_string@ when added).\"",
      "prim agent to_string(value: unknown) -> string",
      "@\"Format any value for f-string interpolation: strings are emitted bare, other values fall back to @to_string@'s JSON form.\"",
      "prim agent format(value: unknown) -> string",
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
      "prim agent get_metadata(value: function) -> agent_metadata"
    ]
