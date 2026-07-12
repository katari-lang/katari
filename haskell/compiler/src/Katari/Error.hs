-- | The user-facing error catalogue: every error the compiler can emit, with its code, severity,
-- and rendering. The accumulation machinery (the writer monoid, emission helpers) lives in
-- "Katari.Diagnostics"; internal-compiler-error aborts in "Katari.Panic".
module Katari.Error where

import Data.Text (Text)
import Data.Text qualified as Text
import GHC.List (List)
import Katari.Data.ModuleName (ModuleName, renderModuleName)
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (SemanticGenericArgument, SemanticType, renderSemanticGenericArgument, renderSemanticType)
import Katari.Data.SourceSpan (Located (..), renderSourceSpan)

-- | Every error the compiler can emit, tagged by the phase that produced it.
data CompilerError where
  CompilerErrorParse :: ParseError -> CompilerError
  CompilerErrorIdentifier :: IdentifierError -> CompilerError
  CompilerErrorType :: TypeError -> CompilerError
  CompilerErrorLowering :: LoweringError -> CompilerError
  deriving (Eq, Ord, Show)

-- | Stable, searchable error code of an error.
-- Code ranges: K1xxx = parser, K2xxx = identifier / name resolution, K3xxx = type system,
-- K4xxx = lowering.
compilerErrorCode :: CompilerError -> Text
compilerErrorCode = \case
  CompilerErrorParse parseError -> parseErrorCode parseError
  CompilerErrorIdentifier identifierError -> identifierErrorCode identifierError
  CompilerErrorType typeError -> typeErrorCode typeError
  CompilerErrorLowering loweringError -> loweringErrorCode loweringError

-- | The severity of a diagnostic. Decided here per error kind (the single source of truth) rather
-- than at each emission site; a policy layer (e.g. @-Werror@) can override later.
data Severity where
  SeverityError :: Severity
  SeverityWarning :: Severity
  deriving (Eq, Ord, Show)

severityOf :: CompilerError -> Severity
severityOf = \case
  CompilerErrorParse parseError -> parseErrorSeverity parseError
  CompilerErrorIdentifier identifierError -> identifierErrorSeverity identifierError
  CompilerErrorType typeError -> typeErrorSeverity typeError
  CompilerErrorLowering loweringError -> loweringErrorSeverity loweringError

-- | Human-readable rendering of one error: code, reason, and the types involved (in surface
-- syntax, via the renderers of "Katari.Data.SemanticType").
renderCompilerError :: CompilerError -> Text
renderCompilerError = \case
  CompilerErrorParse parseError -> renderParseError parseError
  CompilerErrorIdentifier identifierError -> renderIdentifierError identifierError
  CompilerErrorType typeError -> renderTypeError typeError
  CompilerErrorLowering loweringError -> renderLoweringError loweringError

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
    TypeErrorApplicationArity info ->
      "Wrong number of type arguments for "
        <> info.head
        <> " (expected "
        <> Text.pack (show info.expected)
        <> ", actual "
        <> Text.pack (show info.actual)
        <> ")"
    TypeErrorSynonymCycle info -> "Type synonym " <> renderQualifiedName info.name <> " expands to itself (cyclic synonym)"
    TypeErrorMalformedType info -> info.reason
    TypeErrorMisplacedJump info -> "`" <> info.keyword <> "` is only valid inside " <> info.requiredContext
    TypeErrorMissingAnnotation info -> info.reason
    TypeErrorExpectedShape info ->
      "Expected " <> info.expected <> ", but the expression has type " <> renderSemanticType info.actual
    TypeErrorGenericNotApplied info ->
      "This generic value is used without type arguments and is not in a call (type arguments are"
        <> " inferred only at call sites); apply it explicitly to ["
        <> Text.intercalate ", " info.parameters
        <> "]"
    TypeErrorCannotInferGeneric info ->
      "Could not infer the type argument(s) ["
        <> Text.intercalate ", " info.parameters
        <> "] from this application; supply them explicitly (value["
        <> Text.intercalate ", " info.parameters
        <> "])"
    TypeErrorWrongReferenceKind info -> "`" <> info.name <> "` is not " <> info.expected
    TypeErrorUnknownReactor info ->
      "Unknown reactor `"
        <> info.reactor
        <> "` in a `from` clause; the external reactors are "
        <> Text.intercalate ", " info.known
    TypeErrorReservedReactor info ->
      "The `"
        <> info.reactor
        <> "` reactor serves only the compiled stdlib externals, so a user module cannot declare an"
        <> " external `from \""
        <> info.reactor
        <> "\"` — a call would reach the reactor with a key it cannot serve. Implement the external over"
        <> " the FFI instead (omit the `from` clause, or write `from \"ffi\"`)"
    TypeErrorMalformedUse info -> case info.reason of
      MalformedUseWrittenContinuation ->
        "`continuation` is the argument `use` itself passes to its provider — a `use` application cannot also write one"
      MalformedUseProviderShape ->
        "a `use` provider must be a handler or an application — a handler literal, a (qualified) name, or a call; bind any other expression first (`let p = ...` then `use p`, or apply it: `use expression(...)`)"
      MalformedUseHoleArgument ->
        "a `use` provider is applied exactly once, so its application cannot leave a `_` hole; bind the partial application first (`let p = f(x = _, ...)` then `use p`)"
    TypeErrorUnknownHoleLabel info ->
      "`"
        <> info.label
        <> " = _` does not name a parameter of the callee; its parameters are ["
        <> Text.intercalate ", " info.parameters
        <> "]"
    TypeErrorFinallyEffect info ->
      "A `finally` finalizer's net effect must be within `io`, but this body's effect is "
        <> info.effect
        <> ". A finalizer runs at instance termination, when the parent may already be awaiting this"
        <> " instance's cancellation; a request would escalate through that parent (deadlocking against"
        <> " its own cancellation wait), and a control escape has no target there. Perform only `io`"
        <> " (routed to sibling reactors), or handle any request locally inside the `finally` body."

-- | Errors produced by the type-system layer (normalization, union / intersection, subtyping).
data TypeError where
  TypeErrorSubtype :: SubtypeErrorInfo -> TypeError
  TypeErrorCannotBeUnioned :: CannotBeUnionedErrorInfo -> TypeError
  TypeErrorCannotBeIntersected :: CannotBeIntersectedErrorInfo -> TypeError
  TypeErrorKind :: KindErrorInfo -> TypeError
  TypeErrorGenericArity :: GenericArityErrorInfo -> TypeError
  -- | A type application supplies the wrong number of bracket arguments for its head.
  TypeErrorApplicationArity :: ApplicationArityErrorInfo -> TypeError
  -- | A type synonym refers to itself (directly or through other synonyms); expansion would not
  -- terminate, so it is rejected.
  TypeErrorSynonymCycle :: SynonymCycleErrorInfo -> TypeError
  -- | A structurally ill-formed type annotation the other cases do not cover (e.g. applying
  -- arguments to a head that takes none, or an override that does not name a request). The specific
  -- failure is in @reason@.
  TypeErrorMalformedType :: MalformedTypeErrorInfo -> TypeError
  -- | A @return@ / @break@ / @next@ used where its target context does not exist (e.g. @return@ at
  -- module top level, @break@ outside a @for@ or request-handler body).
  TypeErrorMisplacedJump :: MisplacedJumpErrorInfo -> TypeError
  -- | A required type / effect annotation is absent where the checker does not infer one (e.g. a
  -- @use@ binder, a (mutually) recursive agent's return / effect, an agent parameter).
  TypeErrorMissingAnnotation :: MissingAnnotationErrorInfo -> TypeError
  -- | An expression is used where a particular shape is needed (a callable agent, a sequence, an
  -- object) but its type does not provide it.
  TypeErrorExpectedShape :: ExpectedShapeErrorInfo -> TypeError
  -- | A generic value is referenced without explicit type arguments. Generic inference is not
  -- supported, so a generic value must be applied (@value[T, ...]@) at every use site.
  TypeErrorGenericNotApplied :: GenericNotAppliedErrorInfo -> TypeError
  -- | A generic application's type arguments could not be inferred from the call (a parameter has no
  -- argument constraining it). The user must supply the named arguments explicitly (@value[T, ...]@).
  TypeErrorCannotInferGeneric :: CannotInferGenericErrorInfo -> TypeError
  -- | A name resolved by the identifier phase, but to the wrong kind of entity for its position — a
  -- request handler whose name is a data type / synonym / generic, or a constructor pattern whose name
  -- is an agent / request / local rather than a data type. (Namespaces overlap, so resolution alone
  -- cannot rule this out; the checker reports it instead of crashing.)
  TypeErrorWrongReferenceKind :: WrongReferenceKindErrorInfo -> TypeError
  -- | An @external ... from "name"@ clause names a reactor the runtime does not host external calls on
  -- (a typo, or an unimplemented reactor). Rejected at compile time rather than silently defaulting to
  -- the FFI reactor at runtime.
  TypeErrorUnknownReactor :: UnknownReactorErrorInfo -> TypeError
  -- | A USER module's @external ... from "name"@ clause names a built-in reactor (http / webhook / mcp /
  -- time). Those reactors serve only the compiled stdlib externals (they dispatch on the stdlib keys), so
  -- a user-declared external would reach them with a key they cannot serve — a runtime panic at best, a
  -- silent mis-serve at worst. Only the embedded stdlib modules may name them; the user channel is @ffi@
  -- (or no clause). Distinct from an unknown name (K3018): the reactor exists, this module may not name it.
  TypeErrorReservedReactor :: ReservedReactorErrorInfo -> TypeError
  -- | A @use@ statement is written in a shape @use@ does not admit — see 'MalformedUseReason' for the
  -- specific violation. Distinct from a malformed /type/ (K3011): the type expression is fine, the
  -- @use@ construct itself is misused.
  TypeErrorMalformedUse :: MalformedUseErrorInfo -> TypeError
  -- | A partial application's @label = _@ hole names no parameter of the callee. Distinct from a
  -- missing-argument subtype failure (K3001): the hole is extra, not absent, so the residual function
  -- could never receive it.
  TypeErrorUnknownHoleLabel :: UnknownHoleLabelErrorInfo -> TypeError
  -- | A @finally@ finalizer body's net effect is not within @io@ — it performs a request that would
  -- escalate through the parent, or carries a control escape with no target at instance termination.
  -- Distinct from an ordinary subtype failure (K3001): the restriction is peculiar to a finalizer,
  -- which runs while the parent may already be awaiting the instance's cancellation.
  TypeErrorFinallyEffect :: FinallyEffectErrorInfo -> TypeError
  deriving (Eq, Ord, Show)

typeErrorCode :: TypeError -> Text
typeErrorCode = \case
  TypeErrorSubtype _ -> "K3001"
  TypeErrorCannotBeUnioned _ -> "K3005"
  TypeErrorCannotBeIntersected _ -> "K3006"
  TypeErrorKind _ -> "K3007"
  TypeErrorGenericArity _ -> "K3008"
  TypeErrorApplicationArity _ -> "K3009"
  TypeErrorSynonymCycle _ -> "K3010"
  TypeErrorMalformedType _ -> "K3011"
  TypeErrorMisplacedJump _ -> "K3012"
  TypeErrorMissingAnnotation _ -> "K3013"
  TypeErrorExpectedShape _ -> "K3014"
  TypeErrorGenericNotApplied _ -> "K3015"
  TypeErrorCannotInferGeneric _ -> "K3016"
  TypeErrorWrongReferenceKind _ -> "K3017"
  TypeErrorUnknownReactor _ -> "K3018"
  TypeErrorMalformedUse _ -> "K3019"
  TypeErrorUnknownHoleLabel _ -> "K3020"
  TypeErrorFinallyEffect _ -> "K3021"
  TypeErrorReservedReactor _ -> "K3022"

-- | Enumerated explicitly (rather than a catch-all) so adding a type error forces a severity
-- decision. Every current type error fails compilation.
typeErrorSeverity :: TypeError -> Severity
typeErrorSeverity = \case
  TypeErrorSubtype _ -> SeverityError
  TypeErrorCannotBeUnioned _ -> SeverityError
  TypeErrorCannotBeIntersected _ -> SeverityError
  TypeErrorKind _ -> SeverityError
  TypeErrorGenericArity _ -> SeverityError
  TypeErrorApplicationArity _ -> SeverityError
  TypeErrorSynonymCycle _ -> SeverityError
  TypeErrorMalformedType _ -> SeverityError
  TypeErrorMisplacedJump _ -> SeverityError
  TypeErrorMissingAnnotation _ -> SeverityError
  TypeErrorExpectedShape _ -> SeverityError
  TypeErrorGenericNotApplied _ -> SeverityError
  TypeErrorCannotInferGeneric _ -> SeverityError
  TypeErrorWrongReferenceKind _ -> SeverityError
  TypeErrorUnknownReactor _ -> SeverityError
  TypeErrorMalformedUse _ -> SeverityError
  TypeErrorUnknownHoleLabel _ -> SeverityError
  TypeErrorFinallyEffect _ -> SeverityError
  TypeErrorReservedReactor _ -> SeverityError

-- | @reason@ is the specific failure (e.g. which layer disagreed) — not derivable from the types,
-- so it is carried; the rest of every error's text is generated from its structured fields.
data SubtypeErrorInfo = SubtypeErrorInfo
  { expected :: SemanticGenericArgument,
    actual :: SemanticGenericArgument,
    reason :: Text
  }
  deriving (Eq, Ord, Show)

data CannotBeUnionedErrorInfo = CannotBeUnionedErrorInfo
  { left :: SemanticGenericArgument,
    right :: SemanticGenericArgument
  }
  deriving (Eq, Ord, Show)

data CannotBeIntersectedErrorInfo = CannotBeIntersectedErrorInfo
  { left :: SemanticGenericArgument,
    right :: SemanticGenericArgument
  }
  deriving (Eq, Ord, Show)

data KindErrorInfo = KindErrorInfo
  { expected :: Text,
    actual :: Text,
    reason :: Text
  }
  deriving (Eq, Ord, Show)

data GenericArityErrorInfo = GenericArityErrorInfo
  { name :: QualifiedName,
    -- | The declared generic parameter names, in declaration order
    expected :: List Text,
    -- | The argument names actually supplied
    actual :: List Text
  }
  deriving (Eq, Ord, Show)

-- | @head@ is the rendered application head (a synonym / data / request name, or @array@ / @record@),
-- since it is not always a 'QualifiedName'. @expected@ / @actual@ are positional argument counts.
data ApplicationArityErrorInfo = ApplicationArityErrorInfo
  { head :: Text,
    expected :: Int,
    actual :: Int
  }
  deriving (Eq, Ord, Show)

newtype SynonymCycleErrorInfo = SynonymCycleErrorInfo
  { name :: QualifiedName
  }
  deriving (Eq, Ord, Show)

newtype MalformedTypeErrorInfo = MalformedTypeErrorInfo
  { reason :: Text
  }
  deriving (Eq, Ord, Show)

-- | @keyword@ is the jump that has no target (@return@ / @break@ / @next@); @requiredContext@ names
-- the enclosing construct it needs (e.g. "an agent body", "a `for` body").
data MisplacedJumpErrorInfo = MisplacedJumpErrorInfo
  { keyword :: Text,
    requiredContext :: Text
  }
  deriving (Eq, Ord, Show)

newtype MissingAnnotationErrorInfo = MissingAnnotationErrorInfo
  { reason :: Text
  }
  deriving (Eq, Ord, Show)

-- | @expected@ names the shape the position requires (e.g. "a callable agent"); @actual@ is the type
-- the expression actually has, rendered in surface syntax.
data ExpectedShapeErrorInfo = ExpectedShapeErrorInfo
  { expected :: Text,
    actual :: SemanticType
  }
  deriving (Eq, Ord, Show)

-- | @parameters@ are the declared generic parameter names the value still needs explicit arguments for.
newtype GenericNotAppliedErrorInfo = GenericNotAppliedErrorInfo
  { parameters :: List Text
  }
  deriving (Eq, Ord, Show)

-- | @parameters@ are the declared generic parameter names whose arguments the application did not
-- constrain, so they could not be inferred and must be supplied explicitly.
newtype CannotInferGenericErrorInfo = CannotInferGenericErrorInfo
  { parameters :: List Text
  }
  deriving (Eq, Ord, Show)

-- | @name@ is the (surface) name as written; @expected@ names the kind the position requires (e.g.
-- "a request", "a constructor (data type)").
data WrongReferenceKindErrorInfo = WrongReferenceKindErrorInfo
  { name :: Text,
    expected :: Text
  }
  deriving (Eq, Ord, Show)

-- | @reactor@ is the name written in the @from@ clause; @known@ lists the reactors external calls may
-- route to (the surface-visible external reactors).
data UnknownReactorErrorInfo = UnknownReactorErrorInfo
  { reactor :: Text,
    known :: List Text
  }
  deriving (Eq, Ord, Show)

-- | @reactor@ is the built-in reactor name a user module's @from@ clause tried to claim.
newtype ReservedReactorErrorInfo = ReservedReactorErrorInfo
  { reactor :: Text
  }
  deriving (Eq, Ord, Show)

-- | The specific way a @use@ statement is misused; rendered per case so each violation keeps its own
-- guidance text.
data MalformedUseReason
  = -- | A @use@ application writes a @continuation@ argument, but that label is reserved: @use@ itself
    -- passes the continuation (the rest of the block) under it.
    MalformedUseWrittenContinuation
  | -- | The provider expression has no application reading (it is not a handler literal, a name, an
    -- instantiation, or a call), so admitting it would make @use@'s meaning depend on provider syntax.
    MalformedUseProviderShape
  | -- | The provider application leaves a @_@ hole. @use@ applies its provider exactly once (the
    -- continuation is that application's argument), so a partial application has no @use@ reading.
    MalformedUseHoleArgument
  deriving (Eq, Ord, Show)

newtype MalformedUseErrorInfo = MalformedUseErrorInfo
  { reason :: MalformedUseReason
  }
  deriving (Eq, Ord, Show)

-- | @label@ is the hole's label as written; @parameters@ are the callee's declared parameter labels
-- (so the message can point at what the user probably meant).
data UnknownHoleLabelErrorInfo = UnknownHoleLabelErrorInfo
  { label :: Text,
    parameters :: List Text
  }
  deriving (Eq, Ord, Show)

-- | @effect@ is the finalizer body's offending residual effect, rendered in surface syntax (e.g. the
-- request it escalates), so the message can name why the body is not within @io@.
newtype FinallyEffectErrorInfo = FinallyEffectErrorInfo
  { effect :: Text
  }
  deriving (Eq, Ord, Show)

------------------------------------------------------------------------------------------------
-- Parser errors (K1xxx)
------------------------------------------------------------------------------------------------

-- | Errors produced by the parse phase (lexing + parsing). Starter set; more codes are added as the
-- parser distinguishes more failure shapes.
data ParseError where
  ParseErrorSyntax :: SyntaxErrorInfo -> ParseError
  ParseErrorUnsafeIntegerLiteral :: UnsafeIntegerLiteralInfo -> ParseError
  deriving (Eq, Ord, Show)

parseErrorCode :: ParseError -> Text
parseErrorCode = \case
  ParseErrorSyntax _ -> "K1001"
  ParseErrorUnsafeIntegerLiteral _ -> "K1002"

parseErrorSeverity :: ParseError -> Severity
parseErrorSeverity = \case
  ParseErrorSyntax _ -> SeverityError
  ParseErrorUnsafeIntegerLiteral _ -> SeverityWarning

renderParseError :: ParseError -> Text
renderParseError parseError =
  parseErrorCode parseError <> ": " <> case parseError of
    ParseErrorSyntax info -> info.message
    ParseErrorUnsafeIntegerLiteral info ->
      "Integer literal " <> Text.pack (show info.value) <> " exceeds the safe integer range (±(2^53 − 1)) and will lose precision in the runtime's number value."

-- | A syntax / lexical error; the parser produces the human-readable @message@, so it is carried
-- rather than reconstructed from structured fields.
newtype SyntaxErrorInfo = SyntaxErrorInfo
  { message :: Text
  }
  deriving (Eq, Ord, Show)

-- | An integer literal whose magnitude exceeds what the runtime's JS-number value model represents
-- exactly. A warning, not an error: the value is still accepted (narrowed to a machine 'Int').
newtype UnsafeIntegerLiteralInfo = UnsafeIntegerLiteralInfo
  { value :: Integer
  }
  deriving (Eq, Ord, Show)

------------------------------------------------------------------------------------------------
-- Identifier errors (K2xxx)
------------------------------------------------------------------------------------------------

-- | Errors produced by the identifier (name-resolution) phase. Starter set covering the cases the
-- three-namespace resolver detects; shadowing-policy errors are deferred until that policy is fixed.
data IdentifierError where
  -- | A bare name resolves to nothing in scope (in any namespace).
  IdentifierErrorUndefinedName :: UndefinedNameErrorInfo -> IdentifierError
  -- | @module.member@ where the module exports no such member.
  IdentifierErrorUndefinedMember :: UndefinedMemberErrorInfo -> IdentifierError
  -- | Two top-level declarations (or imports) claim the same name in the same namespace.
  IdentifierErrorDuplicateName :: DuplicateNameErrorInfo -> IdentifierError
  -- | @x.y@ where @x@ resolves but not to a module.
  IdentifierErrorNotAModule :: NotAModuleErrorInfo -> IdentifierError
  -- | An import refers to a module that does not exist.
  IdentifierErrorUnknownImportModule :: UnknownImportModuleErrorInfo -> IdentifierError
  -- | An import item is not exported by its source module.
  IdentifierErrorUnknownImportName :: UnknownImportNameErrorInfo -> IdentifierError
  -- | A @with@ modifier targets a name that is not an enclosing @for@ / @handler@ state variable.
  IdentifierErrorUndefinedStateVariable :: UndefinedStateVariableErrorInfo -> IdentifierError
  -- | A user module's name collides with the compiler-reserved @primitive@ / stdlib namespace.
  IdentifierErrorReservedModuleName :: ReservedModuleNameErrorInfo -> IdentifierError
  deriving (Eq, Ord, Show)

identifierErrorCode :: IdentifierError -> Text
identifierErrorCode = \case
  IdentifierErrorUndefinedName _ -> "K2001"
  IdentifierErrorUndefinedMember _ -> "K2002"
  IdentifierErrorDuplicateName _ -> "K2003"
  IdentifierErrorNotAModule _ -> "K2004"
  IdentifierErrorUnknownImportModule _ -> "K2005"
  IdentifierErrorUnknownImportName _ -> "K2006"
  IdentifierErrorUndefinedStateVariable _ -> "K2007"
  IdentifierErrorReservedModuleName _ -> "K2008"

identifierErrorSeverity :: IdentifierError -> Severity
identifierErrorSeverity = \case
  IdentifierErrorUndefinedName _ -> SeverityError
  IdentifierErrorUndefinedMember _ -> SeverityError
  IdentifierErrorDuplicateName _ -> SeverityError
  IdentifierErrorNotAModule _ -> SeverityError
  IdentifierErrorUnknownImportModule _ -> SeverityError
  IdentifierErrorUnknownImportName _ -> SeverityError
  IdentifierErrorUndefinedStateVariable _ -> SeverityError
  IdentifierErrorReservedModuleName _ -> SeverityError

renderIdentifierError :: IdentifierError -> Text
renderIdentifierError identifierError =
  identifierErrorCode identifierError <> ": " <> case identifierError of
    IdentifierErrorUndefinedName info -> "Undefined name: " <> info.name
    IdentifierErrorUndefinedMember info -> "Module " <> renderModuleName info.moduleName <> " has no exported member " <> info.name
    IdentifierErrorDuplicateName info -> "Duplicate declaration of " <> info.name
    IdentifierErrorNotAModule info -> info.name <> " is not a module"
    IdentifierErrorUnknownImportModule info -> "Imported module does not exist: " <> renderModuleName info.moduleName
    IdentifierErrorUnknownImportName info -> "Module " <> renderModuleName info.moduleName <> " does not export " <> info.name
    IdentifierErrorUndefinedStateVariable info -> info.name <> " is not a loop or handler state variable"
    IdentifierErrorReservedModuleName info -> "Module name " <> renderModuleName info.moduleName <> " is reserved by the compiler (the primitive / stdlib namespace)"

newtype UndefinedNameErrorInfo = UndefinedNameErrorInfo
  { name :: Text
  }
  deriving (Eq, Ord, Show)

data UndefinedMemberErrorInfo = UndefinedMemberErrorInfo
  { moduleName :: ModuleName,
    name :: Text
  }
  deriving (Eq, Ord, Show)

newtype DuplicateNameErrorInfo = DuplicateNameErrorInfo
  { name :: Text
  }
  deriving (Eq, Ord, Show)

newtype NotAModuleErrorInfo = NotAModuleErrorInfo
  { name :: Text
  }
  deriving (Eq, Ord, Show)

newtype UnknownImportModuleErrorInfo = UnknownImportModuleErrorInfo
  { moduleName :: ModuleName
  }
  deriving (Eq, Ord, Show)

data UnknownImportNameErrorInfo = UnknownImportNameErrorInfo
  { moduleName :: ModuleName,
    name :: Text
  }
  deriving (Eq, Ord, Show)

newtype UndefinedStateVariableErrorInfo = UndefinedStateVariableErrorInfo
  { name :: Text
  }
  deriving (Eq, Ord, Show)

newtype ReservedModuleNameErrorInfo = ReservedModuleNameErrorInfo
  { moduleName :: ModuleName
  }
  deriving (Eq, Ord, Show)

------------------------------------------------------------------------------------------------
-- Lowering errors (K4xxx)
------------------------------------------------------------------------------------------------

-- | Errors produced by the lowering phase (typed AST to IR). Lowering well-typed code rarely fails,
-- so this is a single catch-all for now.
data LoweringError where
  LoweringErrorUnsupported :: UnsupportedErrorInfo -> LoweringError
  deriving (Eq, Ord, Show)

loweringErrorCode :: LoweringError -> Text
loweringErrorCode = \case
  LoweringErrorUnsupported _ -> "K4001"

loweringErrorSeverity :: LoweringError -> Severity
loweringErrorSeverity = \case
  LoweringErrorUnsupported _ -> SeverityError

renderLoweringError :: LoweringError -> Text
renderLoweringError loweringError =
  loweringErrorCode loweringError <> ": " <> case loweringError of
    LoweringErrorUnsupported info -> info.message

newtype UnsupportedErrorInfo = UnsupportedErrorInfo
  { message :: Text
  }
  deriving (Eq, Ord, Show)
