-- | The wired-in @primitive@ module: the names the compiler hardcodes about it, and the
-- operator → primitive-function desugar table.
--
-- Operators are not a distinct construct past the Identifier pass: @a \<op\> b@ is desugared into a
-- call to the matching @primitive@ function (see "Katari.Identifier.Expression"), so the checker and
-- everything downstream see one uniform call form. This module owns the lexical half of that — which
-- function each operator maps to and the argument labels the desugar emits. The semantic half (the
-- function's actual signature) lives in the embedded @primitive@ source ('Katari.Stdlib'); the two are
-- kept in agreement by "Katari.StdlibSpec".
module Katari.Primitive where

import Data.Text (Text)
import Katari.Data.AST (BinaryOperator (..), UnaryOperator (..))
import Katari.Data.ModuleName (ModuleName (..))

-- | The module every operator desugars into, and the default-import root spliced into every user
-- module's scope ('Katari.Stdlib.defaultImports').
primitiveModuleName :: ModuleName
primitiveModuleName = ModuleName "primitive"

-- | The primitive function a binary operator desugars to: @a \<op\> b@ becomes
-- @primitive.\<name\>(left = a, right = b)@. Every name here must be exported by the @primitive@
-- module (enforced by "Katari.StdlibSpec").
binaryOperatorName :: BinaryOperator -> Text
binaryOperatorName = \case
  BinaryOperatorAdd -> "add"
  BinaryOperatorSubtract -> "subtract"
  BinaryOperatorMultiply -> "multiply"
  BinaryOperatorDivide -> "divide"
  BinaryOperatorModulo -> "modulo"
  BinaryOperatorEqual -> "equal"
  BinaryOperatorNotEqual -> "not_equal"
  BinaryOperatorLessThan -> "less_than"
  BinaryOperatorLessOrEqual -> "less_or_equal"
  BinaryOperatorGreaterThan -> "greater_than"
  BinaryOperatorGreaterOrEqual -> "greater_or_equal"
  BinaryOperatorAnd -> "and"
  BinaryOperatorOr -> "or"
  BinaryOperatorConcat -> "concat"

-- | The primitive function a unary operator desugars to: @\<op\> x@ becomes
-- @primitive.\<name\>(value = x)@.
unaryOperatorName :: UnaryOperator -> Text
unaryOperatorName = \case
  UnaryOperatorNegate -> "negate"
  UnaryOperatorNot -> "not"

-- | The argument labels the operator desugar emits — they must match the parameter names of the
-- primitive signatures ("Katari.StdlibSpec" checks this).
binaryOperatorLeftLabel :: Text
binaryOperatorLeftLabel = "left"

binaryOperatorRightLabel :: Text
binaryOperatorRightLabel = "right"

unaryOperatorOperandLabel :: Text
unaryOperatorOperandLabel = "value"
