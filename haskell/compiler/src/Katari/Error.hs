-- | Centralized catalogue of every error the compiler can emit.
module Katari.Error where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (SemanticGenericArgument, renderSemanticGenericArgument)
import Katari.Data.SourceSpan (Located (..), renderSourceSpan)

-- | Every error the compiler can emit, tagged by the phase that produced it.
data CompilerError where
  CompilerErrorType :: TypeError -> CompilerError
  deriving (Eq, Ord, Show)

-- | Stable, searchable error code of an error.
-- Code ranges (provisional): K1xxx = parser, K2xxx = identifier / name resolution, K3xxx = type system.
compilerErrorCode :: CompilerError -> Text
compilerErrorCode = \case
  CompilerErrorType typeError -> typeErrorCode typeError

-- | The severity of a diagnostic. Decided here per error kind (the single source of truth) rather
-- than at each emission site; a policy layer (e.g. @-Werror@) can override later.
data Severity where
  SeverityError :: Severity
  SeverityWarning :: Severity
  deriving (Eq, Ord, Show)

severityOf :: CompilerError -> Severity
severityOf = \case
  CompilerErrorType typeError -> typeErrorSeverity typeError

-- | Human-readable rendering of one error: code, reason, and the types involved (in surface
-- syntax, via the renderers of "Katari.Data.SemanticType").
renderCompilerError :: CompilerError -> Text
renderCompilerError = \case
  CompilerErrorType typeError -> renderTypeError typeError

-- | As 'renderCompilerError', prefixed with the source location.
renderLocatedCompilerError :: Located CompilerError -> Text
renderLocatedCompilerError located = renderSourceSpan located.sourceSpan <> " " <> renderCompilerError located.value

renderTypeError :: TypeError -> Text
renderTypeError typeError =
  typeErrorCode typeError <> ": " <> case typeError of
    TypeErrorSubtype info ->
      info.reason
        <> "\n  expected: "
        <> renderSemanticGenericArgument info.expected
        <> "\n  actual:   "
        <> renderSemanticGenericArgument info.actual
    TypeErrorUnknownRequest info -> "Unknown request: " <> renderQualifiedName info.expected
    TypeErrorUnknownData info -> "Unknown data: " <> renderQualifiedName info.expected
    TypeErrorUnknownGeneric info -> "Unknown generic argument: " <> info.expected
    TypeErrorCannotBeUnioned info ->
      "Invariant generic arguments must be identical to be unioned"
        <> "\n  left:  "
        <> renderSemanticGenericArgument info.left
        <> "\n  right: "
        <> renderSemanticGenericArgument info.right
    TypeErrorCannotBeIntersected info ->
      "Invariant generic arguments must be identical to be intersected"
        <> "\n  left:  "
        <> renderSemanticGenericArgument info.left
        <> "\n  right: "
        <> renderSemanticGenericArgument info.right
    TypeErrorKind info -> info.reason <> " (expected " <> info.expected <> ", actual " <> info.actual <> ")"
    TypeErrorGenericArity info ->
      "Generic arguments do not match the declaration of "
        <> renderQualifiedName info.name
        <> "\n  expected: ["
        <> Text.intercalate ", " info.expected
        <> "]\n  actual:   ["
        <> Text.intercalate ", " info.actual
        <> "]"

-- | Errors produced by the type-system layer (normalization, union / intersection, subtyping).
data TypeError where
  TypeErrorSubtype :: SubtypeErrorInfo -> TypeError
  TypeErrorUnknownRequest :: UnknownRequestErrorInfo -> TypeError
  TypeErrorUnknownData :: UnknownDataErrorInfo -> TypeError
  TypeErrorUnknownGeneric :: UnknownGenericErrorInfo -> TypeError
  TypeErrorCannotBeUnioned :: CannotBeUnionedErrorInfo -> TypeError
  TypeErrorCannotBeIntersected :: CannotBeIntersectedErrorInfo -> TypeError
  TypeErrorKind :: KindErrorInfo -> TypeError
  TypeErrorGenericArity :: GenericArityErrorInfo -> TypeError
  deriving (Eq, Ord, Show)

typeErrorCode :: TypeError -> Text
typeErrorCode = \case
  TypeErrorSubtype _ -> "K3001"
  TypeErrorUnknownRequest _ -> "K3002"
  TypeErrorUnknownData _ -> "K3003"
  TypeErrorUnknownGeneric _ -> "K3004"
  TypeErrorCannotBeUnioned _ -> "K3005"
  TypeErrorCannotBeIntersected _ -> "K3006"
  TypeErrorKind _ -> "K3007"
  TypeErrorGenericArity _ -> "K3008"

-- | Enumerated explicitly (rather than a catch-all) so adding a type error forces a severity
-- decision. Every current type error fails compilation.
typeErrorSeverity :: TypeError -> Severity
typeErrorSeverity = \case
  TypeErrorSubtype _ -> SeverityError
  TypeErrorUnknownRequest _ -> SeverityError
  TypeErrorUnknownData _ -> SeverityError
  TypeErrorUnknownGeneric _ -> SeverityError
  TypeErrorCannotBeUnioned _ -> SeverityError
  TypeErrorCannotBeIntersected _ -> SeverityError
  TypeErrorKind _ -> SeverityError
  TypeErrorGenericArity _ -> SeverityError

-- | @reason@ is the specific failure (e.g. which layer disagreed) — not derivable from the types,
-- so it is carried; the rest of every error's text is generated from its structured fields.
data SubtypeErrorInfo where
  SubtypeErrorInfo ::
    { expected :: SemanticGenericArgument,
      actual :: SemanticGenericArgument,
      reason :: Text
    } ->
    SubtypeErrorInfo
  deriving (Eq, Ord, Show)

data UnknownRequestErrorInfo where
  UnknownRequestErrorInfo ::
    { expected :: QualifiedName
    } ->
    UnknownRequestErrorInfo
  deriving (Eq, Ord, Show)

data UnknownDataErrorInfo where
  UnknownDataErrorInfo ::
    { expected :: QualifiedName
    } ->
    UnknownDataErrorInfo
  deriving (Eq, Ord, Show)

data UnknownGenericErrorInfo where
  UnknownGenericErrorInfo ::
    { expected :: Text
    } ->
    UnknownGenericErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeUnionedErrorInfo where
  CannotBeUnionedErrorInfo ::
    { left :: SemanticGenericArgument,
      right :: SemanticGenericArgument
    } ->
    CannotBeUnionedErrorInfo
  deriving (Eq, Ord, Show)

data CannotBeIntersectedErrorInfo where
  CannotBeIntersectedErrorInfo ::
    { left :: SemanticGenericArgument,
      right :: SemanticGenericArgument
    } ->
    CannotBeIntersectedErrorInfo
  deriving (Eq, Ord, Show)

data KindErrorInfo where
  KindErrorInfo ::
    { expected :: Text,
      actual :: Text,
      reason :: Text
    } ->
    KindErrorInfo
  deriving (Eq, Ord, Show)

data GenericArityErrorInfo where
  GenericArityErrorInfo ::
    { name :: QualifiedName,
      -- | The declared generic parameter names, in declaration order
      expected :: List Text,
      -- | The argument names actually supplied
      actual :: List Text
    } ->
    GenericArityErrorInfo
  deriving (Eq, Ord, Show)
