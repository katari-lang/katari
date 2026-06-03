-- | Bidirectional type checker (replacing constraint generation + the global
-- unification solver + zonking). See
-- @docs/2026-06-04-bidirectional-typechecker.md@ for the full design.
--
-- The checker walks @Identified@ AST top-down, computing concrete
-- @SemanticType Resolved@ types directly — no type variables, no constraint
-- solving — and emits @Zonked@ AST. The only relational machinery it needs is
-- the already-pure subtype / normalise / union / intersect functions from
-- 'Katari.Typechecker.NormalizedType'.
--
-- Two judgments:
--
--   * 'synthExpr' — synthesise an expression's type bottom-up.
--   * 'checkExpr' — check an expression against an expected type (synthesise,
--     then assert @synthesised <: expected@).
--
-- WORK IN PROGRESS: this module is built incrementally alongside the live
-- constraint pipeline (it is not yet wired into 'Katari.Typechecker'). Forms
-- not yet handled go through 'unsupported', which records a diagnostic and
-- yields a placeholder so the walk stays total.
module Katari.Typechecker.Check
  ( CheckError (..),
    toDiagnostic,
    CheckEnv (..),
    Check,
    runCheck,
    elaborateType,
    subtypeAssert,
    synthExpr,
    checkExpr,
  )
where

import Control.Monad.Reader
import Control.Monad.State.Strict
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.AST
import Katari.Common (LiteralValue (..), QualifiedName (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Id (VariableResolution)
import Katari.SemanticType
import Katari.SourceSpan (HasSourceSpan (..), SourceSpan)
import Katari.Typechecker.Identifier (TypeData (..))
import Katari.Typechecker.NormalizedType
  ( DataFieldEnv,
    normaliseSemantic,
    subtypeNormalizedType,
  )

-- ===========================================================================
-- Errors
-- ===========================================================================

data CheckError
  = -- | @left@ is not a subtype of the expected @right@.
    CheckErrorTypeMismatch SourceSpan (SemanticType Resolved) (SemanticType Resolved)
  | -- | A cyclic type-synonym definition was reached during elaboration.
    CheckErrorTypeSynonymCycle SourceSpan Text
  | -- | A variable reference did not resolve to a known binding (Identifier
    -- should have rejected this already; defensive).
    CheckErrorUnresolvedVariable SourceSpan Text
  | -- | A form the checker does not yet handle (WIP scaffold only).
    CheckErrorUnsupported SourceSpan Text
  deriving (Show)

-- | Convert a 'CheckError' to a unified 'Diagnostic'.
toDiagnostic :: CheckError -> Diagnostic
toDiagnostic = \case
  CheckErrorTypeMismatch sourceSpan actual expected ->
    diagnosticError
      "K0400"
      ("type mismatch: '" <> renderType actual <> "' is not a subtype of '" <> renderType expected <> "'")
      sourceSpan
  CheckErrorTypeSynonymCycle sourceSpan name ->
    diagnosticError "K0200" ("cyclic type synonym '" <> name <> "'") sourceSpan
  CheckErrorUnresolvedVariable sourceSpan name ->
    diagnosticError "K0401" ("unresolved variable '" <> name <> "'") sourceSpan
  CheckErrorUnsupported sourceSpan what ->
    diagnosticError "K0499" ("typechecker (bidirectional, WIP): unsupported form: " <> what) sourceSpan

-- | Placeholder rendering until a shared type pretty-printer is wired in.
renderType :: SemanticType Resolved -> Text
renderType _ = "<type>"

-- ===========================================================================
-- Environment + monad
-- ===========================================================================

data CheckEnv = CheckEnv
  { -- | Type declarations reachable from this module (own + imports). Used to
    -- expand type synonyms during elaboration.
    checkTypeData :: Map QualifiedName TypeData,
    -- | The @data <: object@ field map, built from the resolved data
    -- constructors processed so far.
    checkDataFieldEnv :: DataFieldEnv,
    -- | Type synonyms currently being expanded (cycle detection).
    checkSynonymVisited :: Set QualifiedName,
    -- | Local variable types — parameters, @let@ bindings, pattern bindings,
    -- state vars — and the module's own top-level callable signatures, all
    -- keyed by 'VariableResolution'.
    checkLocals :: Map VariableResolution (SemanticType Resolved),
    -- | The enclosing agent body's declared / expected return type, if any.
    checkExpectedReturn :: Maybe (SemanticType Resolved)
  }

newtype CheckState = CheckState
  { stateErrors :: [CheckError]
  }

type Check = ReaderT CheckEnv (State CheckState)

-- | Run a checker action against an environment, returning the result and the
-- accumulated diagnostics (in source order).
runCheck :: CheckEnv -> Check a -> (a, [CheckError])
runCheck env action =
  let (result, finalState) = runState (runReaderT action env) (CheckState [])
   in (result, reverse finalState.stateErrors)

emitError :: CheckError -> Check ()
emitError err = modify' $ \s -> CheckState (err : s.stateErrors)

lookupLocal :: VariableResolution -> Check (Maybe (SemanticType Resolved))
lookupLocal resolution = asks (Map.lookup resolution . (.checkLocals))

-- ===========================================================================
-- Type elaboration (SyntacticType Identified -> SemanticType Resolved)
-- ===========================================================================

-- | Elaborate a syntactic type into a resolved semantic type, expanding type
-- synonyms transparently (cycles surface as a diagnostic).
elaborateType :: SyntacticType Identified -> Check (SemanticType Resolved)
elaborateType = \case
  TypePrimitive PrimitiveTypeNode {kind} -> pure (primitiveToSemantic kind)
  TypeName TypeNameNode {name} -> resolveTypeRef name
  TypeQualified QualifiedTypeNode {target} -> resolveTypeRef target
  TypeFunction FunctionTypeNode {parameterTypes, returnType, withRequests} -> do
    parameterEntries <- mapM (\(label, pt) -> (,) label <$> elaborateType pt) parameterTypes
    returnSemantic <- elaborateType returnType
    requests <- elaborateRequestList withRequests
    pure (SemanticTypeFunction (requiredParameter <$> Map.fromList parameterEntries) returnSemantic requests)
  TypeArray ArrayTypeNode {elementType} ->
    SemanticTypeArray <$> elaborateType elementType
  TypeTuple TupleTypeNode {elementTypes} ->
    SemanticTypeTuple <$> mapM elaborateType elementTypes
  TypeUnion TypeUnionNode {branches} ->
    unionSemantic <$> mapM elaborateType branches
  TypeLiteral TypeLiteralNode {value} -> pure (literalValueToSemantic value)
  TypeNever _ -> pure SemanticTypeNever
  TypeUnknown _ -> pure SemanticTypeUnknown
  TypeFunctionAny _ -> pure SemanticTypeFunctionAny
  TypeRecord RecordTypeNode {valueType} ->
    SemanticTypeRecord <$> elaborateType valueType
  TypeObject ObjectTypeNode {fields} ->
    SemanticTypeObject . Map.fromList <$> mapM (\(label, fieldType) -> (label,) <$> elaborateType fieldType) fields

resolveTypeRef :: NameRef Identified TypeRef -> Check (SemanticType Resolved)
resolveTypeRef nameRef = case nameRef.resolution of
  Just qualifiedName -> do
    types <- asks (.checkTypeData)
    case Map.lookup qualifiedName types of
      Just TypeData {typeSynonymRhs = Just rhs} -> do
        visited <- asks (.checkSynonymVisited)
        if Set.member qualifiedName visited
          then do
            emitError (CheckErrorTypeSynonymCycle nameRef.sourceSpan qualifiedName.name)
            pure SemanticTypeUnknown
          else local (\e -> e {checkSynonymVisited = Set.insert qualifiedName e.checkSynonymVisited}) (elaborateType rhs)
      Just TypeData {typeSynonymRhs = Nothing} ->
        pure (SemanticTypeData qualifiedName)
      Nothing ->
        pure SemanticTypeUnknown
  Nothing -> pure SemanticTypeUnknown

-- | Elaborate a @with@ clause into a concrete request set (only names that are
-- known requests contribute).
elaborateRequestList :: [SyntacticRequest Identified] -> Check (SemanticRequest Resolved)
elaborateRequestList syntacticRequests =
  pure
    ( SemanticRequest
        ( Set.fromList
            [ SemanticRequestElementConcrete qualifiedName
              | SyntacticRequest {name = NameRef {resolution = Just qualifiedName}} <- syntacticRequests
            ]
        )
    )

primitiveToSemantic :: PrimitiveTypeKind -> SemanticType phase
primitiveToSemantic = \case
  PrimitiveTypeKindNull -> SemanticTypeNull
  PrimitiveTypeKindInteger -> SemanticTypeInteger
  PrimitiveTypeKindNumber -> SemanticTypeNumber
  PrimitiveTypeKindString -> SemanticTypeString
  PrimitiveTypeKindSecret -> SemanticTypeSecret
  PrimitiveTypeKindFile -> SemanticTypeFile
  PrimitiveTypeKindBoolean -> SemanticTypeBoolean

literalValueToSemantic :: LiteralValue -> SemanticType phase
literalValueToSemantic = \case
  LiteralValueNull -> SemanticTypeNull
  LiteralValueInteger n -> SemanticTypeLiteralInteger n
  LiteralValueNumber _ -> SemanticTypeNumber
  LiteralValueString s -> SemanticTypeLiteralString s
  LiteralValueBoolean b -> SemanticTypeLiteralBoolean b
  LiteralValueAgent _ -> SemanticTypeUnknown

-- ===========================================================================
-- Subtype assertion
-- ===========================================================================

-- | Assert @actual <: expected@. On failure, record a 'CheckErrorTypeMismatch'
-- and continue (the caller recovers by stamping the expected type).
subtypeAssert :: SourceSpan -> SemanticType Resolved -> SemanticType Resolved -> Check ()
subtypeAssert sourceSpan actual expected = do
  dataFieldEnv <- asks (.checkDataFieldEnv)
  let holds = subtypeNormalizedType dataFieldEnv (normaliseSemantic actual) (normaliseSemantic expected)
  if holds then pure () else emitError (CheckErrorTypeMismatch sourceSpan actual expected)

-- ===========================================================================
-- Expression checking
-- ===========================================================================

-- | Check an expression against an expected type: synthesise it, then assert
-- the synthesised type is a subtype of the expectation.
checkExpr :: Expression Identified -> SemanticType Resolved -> Check (Expression Zonked)
checkExpr expression expected = do
  (zonked, actual) <- synthExpr expression
  subtypeAssert (sourceSpanOf expression) actual expected
  pure zonked

-- | Synthesise an expression's type bottom-up, producing the zonked node.
synthExpr :: Expression Identified -> Check (Expression Zonked, SemanticType Resolved)
synthExpr = \case
  ExpressionLiteral LiteralExpression {value, sourceSpan} ->
    let semantic = literalValueToSemantic value
     in pure (ExpressionLiteral LiteralExpression {value = value, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionVariable VariableExpression {name, sourceSpan} -> do
    semantic <- case name.resolution of
      Just resolution ->
        lookupLocal resolution >>= \case
          Just found -> pure found
          Nothing -> emitError (CheckErrorUnresolvedVariable sourceSpan name.text) >> pure SemanticTypeUnknown
      Nothing -> emitError (CheckErrorUnresolvedVariable sourceSpan name.text) >> pure SemanticTypeUnknown
    pure (ExpressionVariable VariableExpression {name = retagNameRef name, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionTuple TupleExpression {elements, sourceSpan} -> do
    walked <- mapM synthExpr elements
    let semantic = SemanticTypeTuple (map snd walked)
    pure (ExpressionTuple TupleExpression {elements = map fst walked, sourceSpan = sourceSpan, typeOf = semantic}, semantic)
  ExpressionRecord RecordExpression {entries, sourceSpan} -> do
    walked <- mapM (\(label, e) -> (,) label <$> synthExpr e) entries
    let semantic = SemanticTypeObject (Map.fromList [(label, snd we) | (label, we) <- walked])
    pure
      ( ExpressionRecord RecordExpression {entries = [(label, fst we) | (label, we) <- walked], sourceSpan = sourceSpan, typeOf = semantic},
        semantic
      )
  other -> unsupported other

-- | Placeholder for forms not yet handled: record a diagnostic and yield a
-- @null@ literal of @unknown@ type so the walk stays total. WIP only.
unsupported :: Expression Identified -> Check (Expression Zonked, SemanticType Resolved)
unsupported expression = do
  let sourceSpan = sourceSpanOf expression
  emitError (CheckErrorUnsupported sourceSpan (formName expression))
  pure
    ( ExpressionLiteral LiteralExpression {value = LiteralValueNull, sourceSpan = sourceSpan, typeOf = SemanticTypeUnknown},
      SemanticTypeUnknown
    )

formName :: Expression phase -> Text
formName = \case
  ExpressionLiteral _ -> "literal"
  ExpressionVariable _ -> "variable"
  ExpressionTuple _ -> "tuple"
  ExpressionRecord _ -> "record"
  ExpressionCall _ -> "call"
  ExpressionBinaryOperator _ -> "binary operator"
  ExpressionUnaryOperator _ -> "unary operator"
  ExpressionIf _ -> "if"
  ExpressionMatch _ -> "match"
  ExpressionFor _ -> "for"
  ExpressionBlock _ -> "block"
  ExpressionFieldAccess _ -> "field access"
  ExpressionIndexAccess _ -> "index access"
  ExpressionTemplate _ -> "template literal"
  ExpressionHandle _ -> "handle"
  ExpressionParTuple _ -> "par tuple"
  ExpressionQualifiedReference _ -> "qualified reference"
