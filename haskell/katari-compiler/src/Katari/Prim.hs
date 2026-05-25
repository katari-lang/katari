-- | Built-in primitive metadata.
--
-- Prims are declared as ordinary @primitive@ entries in
-- 'Katari.Stdlib.stdlibSources'; the compiler treats them just like
-- 'Katari.AST.ExternalAgentDeclaration' through Identifier / CG / Zonk /
-- Lowering. The only thing this module owns is:
--
--   * 'PrimRule' — the small set of special typing rules a prim can opt
--     into via the surface @using@ clause (e.g. arithmetic operand-aware
--     return typing).
--   * Operator desugar names — the lexical mapping from binary / unary
--     operators to the prim agent that implements them.
--   * The reserved-name check for @prim@ / @prim.*@ module names
--     (K0113), which lets user code keep the @prim@ namespace exclusive
--     to the stdlib.
module Katari.Prim
  ( PrimRule (..),
    parsePrimRule,
    binaryOperatorPrimName,
    unaryOperatorPrimName,
    isPrimReservedModuleName,
    primSourceSpan,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST
  ( BinaryOperator (..),
    UnaryOperator (..),
  )
import Katari.SourceSpan (Position (..), SourceSpan (..))

-- | Surface-visible typing rule attached to a @prim agent@ declaration
-- via @using rule_name@. Most prims do not need one and are typed
-- straight from their declared signature ('PrimRuleSimple', also the
-- default when @using@ is omitted).
data PrimRule
  = -- | No special rule. The declared @primType@ is the full signature;
    -- standard subtype constraints suffice.
    PrimRuleSimple
  | -- | @lhs, rhs : number@ — result is @lhs ∪ rhs ∪ integer@. Used by
    -- arithmetic prims that preserve integer when both operands are
    -- integer (@add@ / @sub@ / @mul@ / @mod@).
    PrimRuleNumericJoinBinary
  | -- | @value : number@ — result is @value ∪ integer@. Unary analogue
    -- of 'PrimRuleNumericJoinBinary', used by @abs@.
    PrimRuleNumericJoinUnary
  | -- | Every argument is constrained to @string ∪ secret@; the result
    -- type is the supremum of the arguments. So @format(\"hi\")@ →
    -- @string@, @format(some_secret)@ → @secret@, and any
    -- @concat(\"hi\", some_secret)@ → @secret@. Used by @format@ /
    -- @concat@ to make f-string interpolation taint-aware (any secret
    -- in any embedded expression poisons the resulting string), while
    -- statically rejecting integer / boolean f-string interpolation
    -- (the user must @to_string(n)@ them first).
    PrimRuleFstringJoin
  deriving (Eq, Show)

-- | Decode a surface @using <name>@ identifier into a 'PrimRule', or
-- 'Nothing' if the rule name is unknown to the compiler. The Identifier
-- pass uses this to validate the @using@ clause at declaration time.
parsePrimRule :: Text -> Maybe PrimRule
parsePrimRule = \case
  "numeric_join_binary" -> Just PrimRuleNumericJoinBinary
  "numeric_join_unary" -> Just PrimRuleNumericJoinUnary
  "fstring_join" -> Just PrimRuleFstringJoin
  _ -> Nothing

-- | Sentinel source span for synthetic prim nodes (used by operator
-- desugaring sites that inject prim calls). User-facing diagnostics
-- always anchor to the user's source span, not this sentinel.
primSourceSpan :: SourceSpan
primSourceSpan =
  SrcSpan
    { filePath = "<prim>",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }

-- | Whether @name@ is a module name reserved by the prim system. User
-- code that tries to define a module under @primitive@ / @primitive.*@
-- is rejected with K0113.
isPrimReservedModuleName :: Text -> Bool
isPrimReservedModuleName name = name == "primitive" || "primitive." `T.isPrefixOf` name

-- | The prim function name that implements a binary operator. The
-- Identifier pass desugars @a \<op\> b@ into
-- @<binaryOperatorPrimName op>(lhs=a, rhs=b)@.
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
