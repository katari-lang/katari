-- | Built-in primitive registry.
--
-- Primitive operations (arithmetic, comparison, logic, structural access,
-- ...) are modelled as members of a virtual @prim@ module hierarchy that
-- the compiler injects into every user module's top-level scope:
--
--   * The root @prim@ module is wired in as if every user module did
--     @import { add, sub, ..., to_string } from "prim"@ — every prim it
--     exports is in scope under its bare name.
--   * Each @prim.\<sub\>@ module (e.g. future @prim.json@, @prim.array@) is
--     wired in as if every user module did @import "prim.\<sub\>"@ — the
--     last segment becomes a module alias and individual prims are
--     accessed as @\<sub\>.fn@. None ship today, but the Identifier
--     pass already handles the alias-injection path so future additions
--     are a one-liner here.
--
-- Defining a top-level name that collides with a prim is reported as
-- 'Katari.Typechecker.Identifier.ErrorPrimitiveConflict' (K0112), and
-- defining a module under @prim@ / @prim.*@ is reported as
-- 'ErrorReservedPrimitiveModule' (K0113).
--
-- This module is leaf-level: it depends only on 'Katari.Id',
-- 'Katari.SemanticType', 'Katari.Common', and 'Katari.SourceSpan'. The
-- Identifier / ConstraintGenerator / Lowering passes consume the registry
-- through helper accessors below.
module Katari.Prim
  ( PrimDefinition (..),
    PrimConstraintRule (..),
    primDefinitions,
    primDefinitionsByModule,
    primModuleNames,
    primSubModuleNames,
    primSourceSpan,
    isPrimReservedModuleName,
    binaryOperatorPrimName,
    unaryOperatorPrimName,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
  ( BinaryOperator (..),
    UnaryOperator (..),
  )
import Katari.SemanticType
  ( Resolved,
    SemanticRequest,
    SemanticType (..),
    emptyRequest,
  )
import Katari.SourceSpan (Position (..), SourceSpan (..))

-- | The kind of constraint a prim imposes on its call site. 'PrimRuleSimple'
-- defers to @primType@ as a normal function type; the others encode the
-- subtype-flavoured shape that the operator legacy of the language requires.
data PrimConstraintRule
  = -- | Use 'PrimDefinition.primType' as a regular function signature.
    PrimRuleSimple
  | -- | @+@, @-@, @*@: operands floored at @Number@; result floored at
    -- @Integer@ but reflects the operand type when both are @Integer@.
    PrimRuleAddSubMul
  | -- | @/@: operands floored at @Number@; result is @Number@ (division
    -- can produce non-integer values).
    PrimRuleDivide
  | -- | @==@, @!=@: no operand constraint; result is @Boolean@.
    PrimRuleEqLike
  | -- | @<@, @<=@, @>@, @>=@: operands floored at @Number@; result
    -- @Boolean@.
    PrimRuleCompareNumeric
  | -- | @&&@, @||@: operands floored at @Boolean@; result @Boolean@.
    PrimRuleLogical
  | -- | @++@: operands floored at @String@; result @String@.
    PrimRuleConcat
  | -- | Unary @-@: operand floored at @Number@; result @Number@.
    PrimRuleNegate
  | -- | Unary @!@: operand floored at @Boolean@; result @Boolean@.
    PrimRuleNot
  | -- | Unary @abs@: operand floored at @Number@; result is the operand
    -- type joined with @Integer@ (mirrors 'PrimRuleAddSubMul'). I.e.
    -- @abs(integer) -> integer@, @abs(number) -> number@.
    PrimRuleAbs
  | -- | @get_metadata(value)@: operand subtype of 'SemanticTypeFunctionAny'
    -- (any callable); result is the stdlib data type
    -- @prim.agent_metadata@ (resolved per call site against the Identifier
    -- type table, since stdlib type ids aren't known at 'Prim'-table
    -- construction time).
    PrimRuleGetMetadata
  deriving (Eq, Show)

-- | A built-in primitive definition.
data PrimDefinition = PrimDefinition
  { -- | Bare name as it appears in the module's export table and as the
    -- 'BlockPrim.name' string in IR. The runtime ('prim.ts') dispatches
    -- on this exact value.
    primName :: Text,
    -- | Module under which this prim is registered. Always begins with
    -- @"prim"@ — either @"prim"@ itself (root, named-import injected)
    -- or @"prim.<sub>"@ (qualified-import injected as @<sub>@).
    primModule :: Text,
    -- | Function-shaped signature (parameters / return / effects). For
    -- operator-style prims that need subtyped result types, the
    -- signature here is approximate; the real per-call constraint is
    -- emitted via 'primConstraintRule'.
    primType :: SemanticType Resolved,
    -- | Effect set declared by the prim. Almost always 'emptyRequest'.
    primEffect :: SemanticRequest Resolved,
    -- | How the constraint generator should treat call sites of this
    -- prim. See 'PrimConstraintRule'.
    primConstraintRule :: PrimConstraintRule
  }

-- | Sentinel source span for prim definitions. Used wherever the AST /
-- diagnostic infrastructure expects a 'SourceSpan' for a synthesised
-- prim node. User-facing diagnostics that mention prims always anchor
-- to the user's source span, not this sentinel.
primSourceSpan :: SourceSpan
primSourceSpan =
  SrcSpan
    { filePath = "<prim>",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }

-- | The complete prim registry.
--
-- Adding a new prim is a one-line append here. The Identifier / CG /
-- Lowering passes consume the list reflectively via the helpers below.
primDefinitions :: [PrimDefinition]
primDefinitions =
  [ binary "add" PrimRuleAddSubMul,
    binary "sub" PrimRuleAddSubMul,
    binary "mul" PrimRuleAddSubMul,
    binary "div" PrimRuleDivide,
    -- @%@: integer/integer → integer, anything-number → number (same
    -- subtype shape as add/sub/mul). Runtime uses floor-mod semantics
    -- (result rounds toward negative infinity), matching Python's @%@.
    binary "mod" PrimRuleAddSubMul,
    unary "neg" SemanticTypeNumber SemanticTypeNumber PrimRuleNegate,
    -- @abs@: integer → integer, number → number. Same shape as the
    -- binary arithmetic rule but unary.
    unary "abs" SemanticTypeNumber SemanticTypeNumber PrimRuleAbs,
    binaryEq "eq",
    binaryEq "ne",
    binaryCompare "lt",
    binaryCompare "le",
    binaryCompare "gt",
    binaryCompare "ge",
    binaryLogical "and",
    binaryLogical "or",
    unary "not" SemanticTypeBoolean SemanticTypeBoolean PrimRuleNot,
    PrimDefinition
      { primName = "concat",
        primModule = "prim",
        primType =
          SemanticTypeFunction
            (Map.fromList [("lhs", SemanticTypeString), ("rhs", SemanticTypeString)])
            SemanticTypeString
            emptyRequest,
        primEffect = emptyRequest,
        primConstraintRule = PrimRuleConcat
      },
    -- Aggregate / structural prims. These are 'PrimRuleSimple' and only
    -- appear as call targets emitted by the lowering pass (field /
    -- index / template-literal access). User code cannot reference them
    -- by name today (they require type-system support that doesn't
    -- exist yet — e.g. row polymorphism for get_field), but the
    -- registry entries make them reachable from Lowering.
    simple
      "array_get"
      [("array", SemanticTypeArray SemanticTypeUnknown), ("index", SemanticTypeInteger)]
      SemanticTypeUnknown,
    simple
      "array_length"
      [("array", SemanticTypeArray SemanticTypeUnknown)]
      SemanticTypeInteger,
    simple
      "get_field"
      [("object", SemanticTypeUnknown), ("field", SemanticTypeString)]
      SemanticTypeUnknown,
    simple
      "tuple_get"
      [("tuple", SemanticTypeUnknown), ("index", SemanticTypeInteger)]
      SemanticTypeUnknown,
    simple "type_of" [("value", SemanticTypeUnknown)] SemanticTypeString,
    simple "to_string" [("value", SemanticTypeUnknown)] SemanticTypeString,
    -- AI tool-calling foundation: yields the agent_metadata data value
    -- (name / id / description / input / output) of any callable. The
    -- primType here is an approximation — the real per-call rule pins
    -- the result to @prim.agent_metadata@ via 'PrimRuleGetMetadata'.
    PrimDefinition
      { primName = "get_metadata",
        primModule = "prim",
        primType =
          SemanticTypeFunction
            (Map.singleton "value" SemanticTypeFunctionAny)
            SemanticTypeUnknown
            emptyRequest,
        primEffect = emptyRequest,
        primConstraintRule = PrimRuleGetMetadata
      }
  ]
  where
    binary name rule =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList [("lhs", SemanticTypeNumber), ("rhs", SemanticTypeNumber)])
              SemanticTypeNumber
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = rule
        }
    binaryEq name =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList [("lhs", SemanticTypeUnknown), ("rhs", SemanticTypeUnknown)])
              SemanticTypeBoolean
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = PrimRuleEqLike
        }
    binaryCompare name =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList [("lhs", SemanticTypeNumber), ("rhs", SemanticTypeNumber)])
              SemanticTypeBoolean
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = PrimRuleCompareNumeric
        }
    binaryLogical name =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList [("lhs", SemanticTypeBoolean), ("rhs", SemanticTypeBoolean)])
              SemanticTypeBoolean
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = PrimRuleLogical
        }
    unary name argType resultType rule =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList [("value", argType)])
              resultType
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = rule
        }
    simple name params resultType =
      PrimDefinition
        { primName = name,
          primModule = "prim",
          primType =
            SemanticTypeFunction
              (Map.fromList params)
              resultType
              emptyRequest,
          primEffect = emptyRequest,
          primConstraintRule = PrimRuleSimple
        }

-- | Index 'primDefinitions' by their @primModule@ field for O(log n)
-- per-module lookup.
primDefinitionsByModule :: Map Text [PrimDefinition]
primDefinitionsByModule =
  Map.fromListWith (<>) [(p.primModule, [p]) | p <- primDefinitions]

-- | All prim module names (e.g. @["prim"]@ today; @["prim", "prim.json",
-- ...]@ once sub-modules are added). Both root and sub-modules.
primModuleNames :: [Text]
primModuleNames = Map.keys primDefinitionsByModule

-- | Names of @prim.\<sub\>@ sub-modules, with the @"prim."@ prefix
-- stripped. Used by Identifier to inject these as module aliases into
-- every user module. Empty today.
primSubModuleNames :: [Text]
primSubModuleNames = mapMaybe (T.stripPrefix "prim.") primModuleNames

-- | Whether @name@ is a module name reserved by the prim system. User
-- code that tries to define a module under such a name is rejected
-- with K0113.
isPrimReservedModuleName :: Text -> Bool
isPrimReservedModuleName name = name == "prim" || "prim." `T.isPrefixOf` name

-- | The prim function name that implements a binary operator. The
-- Identifier pass desugars @a \<op\> b@ into @<binaryOperatorPrimName op>(lhs=a, rhs=b)@.
binaryOperatorPrimName :: BinaryOperator -> Text
binaryOperatorPrimName = \case
  BinaryOperatorAdd -> "add"
  BinaryOperatorSubtract -> "sub"
  BinaryOperatorMultiply -> "mul"
  BinaryOperatorDivide -> "div"
  BinaryOperatorModulo -> "mod"
  BinaryOperatorEqual -> "eq"
  BinaryOperatorNotEqual -> "ne"
  BinaryOperatorLessThan -> "lt"
  BinaryOperatorLessOrEqual -> "le"
  BinaryOperatorGreaterThan -> "gt"
  BinaryOperatorGreaterOrEqual -> "ge"
  BinaryOperatorAnd -> "and"
  BinaryOperatorOr -> "or"
  BinaryOperatorConcat -> "concat"

-- | The prim function name that implements a unary operator. Identifier
-- desugar emits a @value@-labelled call argument for the operand.
unaryOperatorPrimName :: UnaryOperator -> Text
unaryOperatorPrimName = \case
  UnaryOperatorNegate -> "neg"
  UnaryOperatorNot -> "not"
