-- | The wired-in @prelude@ module (the operator / panic home): the names the compiler hardcodes
-- about it, and the operator → prelude-function desugar table. (The module is named @prelude@, not
-- @primitive@: @primitive@ is a declaration keyword, so it could never be referenced from source.)
--
-- Operators are not a distinct construct past the Identifier pass: @a \<op\> b@ is desugared into a
-- call to the matching @prelude@ function (see "Katari.Identifier.Expression"), so the checker and
-- everything downstream see one uniform call form. This module owns the lexical half of that — which
-- function each operator maps to and the argument labels the desugar emits. The semantic half (the
-- function's actual signature) lives in the embedded @prelude@ source ('Katari.Stdlib'); the two are
-- kept in agreement by "Katari.StdlibSpec".
module Katari.Primitive where

import Data.Text (Text)
import Katari.Data.AST (BinaryOperator (..), UnaryOperator (..))
import Katari.Data.ModuleName (ModuleName (..))
import Katari.Data.QualifiedName (QualifiedName (..))

-- | The module every operator desugars into, and the default-import root spliced into every user
-- module's scope ('Katari.Stdlib.defaultImports').
preludeModuleName :: ModuleName
preludeModuleName = ModuleName "prelude"

-- | The wired-in @panic@ request. It is deliberately NOT declared in prelude source — a program can
-- neither raise a panic nor list it in an effect row — but a handler may catch one with a special ambient
-- clause @request panic(msg) { ... }@. The checker recognizes that bare clause structurally (it never
-- resolves, being undeclared), types it as @panic(msg: string) -> never@ kept OUT of the continuation's
-- effect row (so it is addable to any handler), and lowers it to this name — matching the runtime's
-- @prelude.panic@ ask.
panicRequestName :: QualifiedName
panicRequestName = QualifiedName {moduleName = preludeModuleName, name = "panic"}

-- | The wired-in @prelude.record.merge@ primitive. Lowering synthesizes a call to it inside a
-- partial application's residual body: merging the residual's incoming argument record with the
-- captured supplied fields preserves the ABSENCE of an omitted optional parameter (a field-by-field
-- rebuild would turn absent into @null@ and defeat the callee's runtime defaults).
recordMergeName :: QualifiedName
recordMergeName = QualifiedName {moduleName = ModuleName "prelude.record", name = "merge"}

-- | The prelude function a binary operator desugars to: @a \<op\> b@ becomes
-- @prelude.\<name\>(left = a, right = b)@. Every name here must be exported by the @prelude@
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

-- | The prelude function a unary operator desugars to: @\<op\> x@ becomes
-- @prelude.\<name\>(value = x)@.
unaryOperatorName :: UnaryOperator -> Text
unaryOperatorName = \case
  UnaryOperatorNegate -> "negate"
  UnaryOperatorNot -> "not"

-- | The argument labels the operator desugar emits — they must match the parameter names of the
-- prelude signatures ("Katari.StdlibSpec" checks this).
binaryOperatorLeftLabel :: Text
binaryOperatorLeftLabel = "left"

binaryOperatorRightLabel :: Text
binaryOperatorRightLabel = "right"

unaryOperatorOperandLabel :: Text
unaryOperatorOperandLabel = "value"
