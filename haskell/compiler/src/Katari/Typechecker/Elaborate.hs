-- | The Elaborate step (Phase A of the checker): turn a name-resolved, kind-agnostic
-- 'SyntacticTypeExpression' into a kind-tagged 'SemanticGenericArgument' (a type, an effect, or an
-- attribute). The parser cannot tell which kind a bare name or a @|@ union denotes; the identifier
-- resolved the names; here we finally split the syntax by kind, expand type synonyms, and assemble
-- the semantic form the lattice ("Katari.Typechecker.Normalizer") consumes.
--
-- Elaboration is shared infrastructure: the global env-build ("Katari.Typechecker.Environment") uses
-- it to elaborate every declaration's annotated types, and the per-module checker (later) uses it for
-- local annotations. It is parameterised by an 'ElaborateContext' — the signature registry of every
-- data / request / synonym, plus the generic-id substitution in force (synonym expansion binds the
-- synonym's parameters into it).
--
-- A leaf whose name the identifier left unresolved elaborates to 'Nothing' (poison): the K2xxx
-- diagnostic was already emitted, so elaboration stays silent and the @require*@ helpers default it
-- to their kind's bottom rather than cascade a spurious kind error.
module Katari.Typechecker.Elaborate where

import Control.Monad (unless, zipWithM)
import Control.Monad.RWS.CPS (RWS, ask, asks, local, runRWS)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.AST
import Katari.Data.Environment (GenericParameterInformation (..), GenericParameters (..))
import Katari.Data.GenericKind (GenericKind (..), renderGenericKind)
import Katari.Data.Id (GenericId, TypeResolution (..))
import Katari.Data.QualifiedName (QualifiedName, renderQualifiedName)
import Katari.Data.SemanticType (FieldInformation (..), SemanticAttribute (..), SemanticEffect (..), SemanticGenericArgument (..), SemanticType (..))
import Katari.Data.SourceSpan (SourceSpan, sourceSpanOf)
import Katari.Diagnostics (Diagnostics, reportAt)
import Katari.Error (ApplicationArityErrorInfo (..), CompilerError (..), KindErrorInfo (..), MalformedTypeErrorInfo (..), SynonymCycleErrorInfo (..), TypeError (..))

------------------------------------------------------------------------------------------------
-- The elaborator monad and its context
------------------------------------------------------------------------------------------------

-- | A type synonym as the elaborator sees it: its generics and the still-syntactic (identified) body
-- to expand. The body is kept raw — not pre-elaborated — so expansion under a fresh argument
-- substitution is a plain recursive 'elaborate'.
data SynonymSignature = SynonymSignature
  { genericParameters :: GenericParameters,
    body :: SyntacticTypeExpression Identified
  }
  deriving (Eq, Show)

-- | Everything elaboration consults. The three signature maps are the read-only registry of nominal
-- declarations; 'substitution' and 'visitingSynonyms' change as the in-scope generics and synonym
-- expansion descend.
data ElaborateContext = ElaborateContext
  { dataSignatures :: Map QualifiedName GenericParameters,
    requestSignatures :: Map QualifiedName GenericParameters,
    synonymSignatures :: Map QualifiedName SynonymSignature,
    -- | What every in-scope generic id elaborates to. A declaration's own generic stands for its own
    -- scheme variable ('withOwnGenerics' seeds these at the declared kind); a synonym's parameter is
    -- bound to its argument while the synonym is expanded. A bare type-name reference no longer carries
    -- its kind (see 'Katari.Data.Id.TypeResolution'), so this binding is also where a generic leaf's
    -- kind comes from.
    substitution :: Map GenericId SemanticGenericArgument,
    -- | Synonyms currently mid-expansion, so a (mutually) recursive synonym is rejected instead of
    -- looping.
    visitingSynonyms :: Set QualifiedName
  }
  deriving (Eq, Show)

-- | A fresh context over a signature registry, with nothing in scope and nothing being expanded —
-- the starting point before 'withOwnGenerics' brings a declaration's generics into scope.
emptyContext ::
  Map QualifiedName GenericParameters ->
  Map QualifiedName GenericParameters ->
  Map QualifiedName SynonymSignature ->
  ElaborateContext
emptyContext dataSignatures requestSignatures synonymSignatures =
  ElaborateContext
    { dataSignatures = dataSignatures,
      requestSignatures = requestSignatures,
      synonymSignatures = synonymSignatures,
      substitution = mempty,
      visitingSynonyms = mempty
    }

type Elaborate a = RWS ElaborateContext Diagnostics () a

runElaborate :: ElaborateContext -> Elaborate a -> (a, Diagnostics)
runElaborate context action = let (result, _, diagnostics) = runRWS action context () in (result, diagnostics)

-- | The scheme variable an own generic parameter stands for, tagged at its declared kind.
schemeVariableFor :: GenericKind -> GenericId -> SemanticGenericArgument
schemeVariableFor kind genericId = case kind of
  GenericKindType -> SemanticGenericArgumentType (SemanticTypeGeneric genericId)
  GenericKindEffect -> SemanticGenericArgumentEffect (SemanticEffectGeneric genericId)
  GenericKindAttribute -> SemanticGenericArgumentAttribute (SemanticAttributeGeneric genericId)

-- | Elaborate @body@ with @parameters@ in scope as their own scheme variables: a declaration's body
-- references its own generics, which must elaborate to scheme variables (not substituted away) at the
-- kind the declaration gave them.
withOwnGenerics :: GenericParameters -> Elaborate a -> Elaborate a
withOwnGenerics parameters =
  local (\context -> context {substitution = Map.union ownGenerics context.substitution})
  where
    ownGenerics = Map.fromList [(info.genericId, schemeVariableFor info.kind info.genericId) | info <- Map.elems parameters.parameterInformation]

-- | Add a set of in-scope generics to an 'ElaborateContext', so the checker can elaborate a body
-- annotation that references an agent / handler generic at the generic's declared kind rather than
-- the type-kinded default of 'elaborateGeneric'.
scopeGenerics :: Map GenericId GenericParameterInformation -> ElaborateContext -> ElaborateContext
scopeGenerics generics context =
  context {substitution = Map.union scoped context.substitution}
  where
    scoped = Map.mapWithKey (\genericId info -> schemeVariableFor info.kind genericId) generics

reportTypeError :: SourceSpan -> TypeError -> Elaborate ()
reportTypeError sourceSpan typeError = reportAt sourceSpan (CompilerErrorType typeError)

reportMalformed :: SourceSpan -> Text -> Elaborate ()
reportMalformed sourceSpan reason = reportTypeError sourceSpan (TypeErrorMalformedType (MalformedTypeErrorInfo {reason = reason}))

------------------------------------------------------------------------------------------------
-- Kind coercion. Elaboration self-determines each node's kind; these enforce the kind a position
-- demands, defaulting poison (and reporting a mismatch otherwise) to the kind's bottom.
------------------------------------------------------------------------------------------------

kindOfArgument :: SemanticGenericArgument -> GenericKind
kindOfArgument = \case
  SemanticGenericArgumentType _ -> GenericKindType
  SemanticGenericArgumentEffect _ -> GenericKindEffect
  SemanticGenericArgumentAttribute _ -> GenericKindAttribute

reportKindMismatch :: SourceSpan -> GenericKind -> GenericKind -> Elaborate ()
reportKindMismatch sourceSpan expected actual =
  reportTypeError sourceSpan $
    TypeErrorKind
      KindErrorInfo
        { -- The renderer appends "(expected …, actual …)", so the reason states only the context, not
          -- the kinds again.
          expected = renderGenericKind expected,
          actual = renderGenericKind actual,
          reason = "This expression has the wrong kind"
        }

requireType :: SourceSpan -> Maybe SemanticGenericArgument -> Elaborate SemanticType
requireType sourceSpan = \case
  Nothing -> pure SemanticTypeNever
  Just (SemanticGenericArgumentType semanticType) -> pure semanticType
  Just other -> SemanticTypeNever <$ reportKindMismatch sourceSpan GenericKindType (kindOfArgument other)

requireEffect :: SourceSpan -> Maybe SemanticGenericArgument -> Elaborate SemanticEffect
requireEffect sourceSpan = \case
  Nothing -> pure SemanticEffectPure
  Just (SemanticGenericArgumentEffect effect) -> pure effect
  Just other -> SemanticEffectPure <$ reportKindMismatch sourceSpan GenericKindEffect (kindOfArgument other)

requireAttribute :: SourceSpan -> Maybe SemanticGenericArgument -> Elaborate SemanticAttribute
requireAttribute sourceSpan = \case
  Nothing -> pure SemanticAttributePublic
  Just (SemanticGenericArgumentAttribute attribute) -> pure attribute
  Just other -> SemanticAttributePublic <$ reportKindMismatch sourceSpan GenericKindAttribute (kindOfArgument other)

-- | Coerce an elaborated node to a required kind, wrapping it back as a 'SemanticGenericArgument'.
requireArgumentKind :: SourceSpan -> GenericKind -> Maybe SemanticGenericArgument -> Elaborate SemanticGenericArgument
requireArgumentKind sourceSpan kind argument = case kind of
  GenericKindType -> SemanticGenericArgumentType <$> requireType sourceSpan argument
  GenericKindEffect -> SemanticGenericArgumentEffect <$> requireEffect sourceSpan argument
  GenericKindAttribute -> SemanticGenericArgumentAttribute <$> requireAttribute sourceSpan argument

elaborateAsType :: SyntacticTypeExpression Identified -> Elaborate SemanticType
elaborateAsType expression = requireType (sourceSpanOf expression) =<< elaborate expression

elaborateAsEffect :: SyntacticTypeExpression Identified -> Elaborate SemanticEffect
elaborateAsEffect expression = requireEffect (sourceSpanOf expression) =<< elaborate expression

elaborateAsAttribute :: SyntacticTypeExpression Identified -> Elaborate SemanticAttribute
elaborateAsAttribute expression = requireAttribute (sourceSpanOf expression) =<< elaborate expression

------------------------------------------------------------------------------------------------
-- The elaboration walk
------------------------------------------------------------------------------------------------

pureType :: SemanticType -> Elaborate (Maybe SemanticGenericArgument)
pureType = pure . Just . SemanticGenericArgumentType

pureEffect :: SemanticEffect -> Elaborate (Maybe SemanticGenericArgument)
pureEffect = pure . Just . SemanticGenericArgumentEffect

pureAttribute :: SemanticAttribute -> Elaborate (Maybe SemanticGenericArgument)
pureAttribute = pure . Just . SemanticGenericArgumentAttribute

-- | Elaborate one type-level expression to its kind-tagged semantic form, or 'Nothing' (poison) when
-- it rests on an unresolved name.
elaborate :: SyntacticTypeExpression Identified -> Elaborate (Maybe SemanticGenericArgument)
elaborate = \case
  TypePrimitive node ->
    pureType $ case node.kind of
      PrimitiveTypeKindNull -> SemanticTypeNull
      PrimitiveTypeKindInteger -> SemanticTypeInteger
      PrimitiveTypeKindNumber -> SemanticTypeNumber
      PrimitiveTypeKindString -> SemanticTypeString
      PrimitiveTypeKindBoolean -> SemanticTypeBoolean
      PrimitiveTypeKindFile -> SemanticTypeFile
  TypeNever _ -> pureType SemanticTypeNever
  TypeUnknown _ -> pureType SemanticTypeUnknown
  TypeAll _ -> pureEffect SemanticEffectAny
  -- A bare @array@ / @record@ is the homogeneous top: an array / record of unknown.
  TypeArray _ -> pureType (SemanticTypeArray SemanticTypeUnknown)
  TypeRecord _ -> pureType (SemanticTypeRecord SemanticTypeUnknown)
  TypeName node -> elaborateNameApplied node [] node.sourceSpan
  TypeApplication node -> elaborateApplication node
  TypeAgent node -> do
    parameterType <- elaborateAsType node.parameterType
    returnType <- elaborateAsType node.returnType
    effect <- maybe (pure SemanticEffectPure) elaborateAsEffect node.effects
    pureType $ SemanticTypeAgent parameterType returnType effect
  TypeTuple node -> do
    elementTypes <- traverse elaborateAsType node.elementTypes
    pureType $ SemanticTypeTuple elementTypes
  TypeObject node -> do
    fields <- traverse elaborateObjectField node.fields
    pureType $ SemanticTypeObject (Map.fromList fields)
  TypeUnion node -> elaborateUnion node
  TypeAttributed node -> do
    base <- elaborate node.baseType
    attribute <- elaborateAsAttribute node.attribute
    case base of
      Nothing -> pure Nothing
      Just (SemanticGenericArgumentType semanticType) -> pureType $ SemanticTypeAttribute semanticType attribute
      Just other -> do
        reportKindMismatch (sourceSpanOf node.baseType) GenericKindType (kindOfArgument other)
        pure Nothing
  TypeAttributeLiteral node ->
    pureAttribute $ case node.kind of
      AttributeLiteralPublic -> SemanticAttributePublic
      AttributeLiteralPrivate -> SemanticAttributePrivate
  TypeOverride node -> do
    base <- elaborateAsEffect node.base
    overrides <- traverse elaborateOverrideEntry node.overrides
    pureEffect $ SemanticEffectOverwrite base (catMaybes overrides)

elaborateObjectField :: ObjectTypeField Identified -> Elaborate (Text, FieldInformation)
elaborateObjectField field = do
  semanticType <- elaborateAsType field.fieldType
  pure (field.name, FieldInformation {semanticType = semanticType, optional = field.optional})

-- | A union is kind-agnostic: elaborate every branch, drop poison, take the first survivor's kind as
-- the union's kind, and coerce the rest to it (a mismatched branch reports a kind error). With every
-- branch poison the whole union is poison.
elaborateUnion :: TypeUnionNode Identified -> Elaborate (Maybe SemanticGenericArgument)
elaborateUnion node = do
  branches <- traverse (\branch -> (,) (sourceSpanOf branch) <$> elaborate branch) node.branches
  let present = [(branchSpan, argument) | (branchSpan, Just argument) <- branches]
  case present of
    [] -> pure Nothing
    ((_, first) : _) ->
      -- The first present branch fixes the union's kind; every branch is coerced to it (a mismatched
      -- branch reports a kind error and contributes its kind's bottom).
      Just <$> case kindOfArgument first of
        GenericKindType -> SemanticGenericArgumentType . SemanticTypeUnion <$> traverse (\(branchSpan, argument) -> requireType branchSpan (Just argument)) present
        GenericKindEffect -> SemanticGenericArgumentEffect . SemanticEffectUnion <$> traverse (\(branchSpan, argument) -> requireEffect branchSpan (Just argument)) present
        GenericKindAttribute -> SemanticGenericArgumentAttribute . SemanticAttributeUnion <$> traverse (\(branchSpan, argument) -> requireAttribute branchSpan (Just argument)) present

-- | An effect override entry must name a request; anything else is reported and dropped.
elaborateOverrideEntry :: SyntacticTypeExpression Identified -> Elaborate (Maybe (QualifiedName, Map Text SemanticGenericArgument))
elaborateOverrideEntry expression = do
  effect <- elaborateAsEffect expression
  case effect of
    SemanticEffectRequest qualifiedName arguments -> pure (Just (qualifiedName, arguments))
    _ -> Nothing <$ reportMalformed (sourceSpanOf expression) "An effect override must name a request"

------------------------------------------------------------------------------------------------
-- Names and applications
------------------------------------------------------------------------------------------------

-- | A (possibly applied) type name. @arguments@ is empty for a bare name; @applicationSpan@ anchors an
-- arity error.
elaborateNameApplied :: TypeNameNode Identified -> List (SyntacticTypeExpression Identified) -> SourceSpan -> Elaborate (Maybe SemanticGenericArgument)
elaborateNameApplied node arguments applicationSpan = case node.typeReference.resolution of
  -- The identifier already reported the undefined name (K2xxx); stay silent.
  Nothing -> pure Nothing
  Just (TypeResolutionGeneric genericId) -> elaborateGeneric node genericId arguments
  Just (TypeResolutionQualifiedName qualifiedName) -> elaborateQualified qualifiedName arguments applicationSpan

-- | A generic name elaborates to whatever the in-scope 'substitution' binds it to — its own scheme
-- variable, or the argument a synonym expansion bound it to. A generic cannot be applied to arguments.
-- An id absent from the substitution should not arise for an in-scope name; default to a type scheme
-- variable rather than fail.
elaborateGeneric :: TypeNameNode Identified -> GenericId -> List (SyntacticTypeExpression Identified) -> Elaborate (Maybe SemanticGenericArgument)
elaborateGeneric node genericId arguments = do
  unless (null arguments) $ reportMalformed node.sourceSpan "A generic parameter cannot be applied to type arguments"
  substitution <- asks (.substitution)
  pure $ Just $ Map.findWithDefault (SemanticGenericArgumentType (SemanticTypeGeneric genericId)) genericId substitution

-- | A nominal name: a data type (a type), a request (an effect), or a synonym (expanded). The three
-- live in disjoint namespaces, so at most one registry holds the name.
elaborateQualified :: QualifiedName -> List (SyntacticTypeExpression Identified) -> SourceSpan -> Elaborate (Maybe SemanticGenericArgument)
elaborateQualified qualifiedName arguments applicationSpan = do
  context <- ask
  case ( Map.lookup qualifiedName context.dataSignatures,
         Map.lookup qualifiedName context.requestSignatures,
         Map.lookup qualifiedName context.synonymSignatures
       ) of
    (Just parameters, _, _) -> do
      maybeArguments <- elaborateArgumentList (renderQualifiedName qualifiedName) parameters arguments applicationSpan
      maybe (pure Nothing) (pureType . SemanticTypeData qualifiedName) maybeArguments
    (_, Just parameters, _) -> do
      maybeArguments <- elaborateArgumentList (renderQualifiedName qualifiedName) parameters arguments applicationSpan
      maybe (pure Nothing) (pureEffect . SemanticEffectRequest qualifiedName) maybeArguments
    (_, _, Just synonym) -> elaborateSynonym qualifiedName synonym arguments applicationSpan
    (Nothing, Nothing, Nothing) ->
      -- The identifier resolved this to a qualified name, but it is no nominal type. A reference to a
      -- value (e.g. an agent) in a type position is the only way here, which the identifier's
      -- namespacing should already forbid; report rather than panic, to be safe.
      Nothing <$ reportMalformed applicationSpan (renderQualifiedName qualifiedName <> " is not a type, effect, or attribute")

-- | Expand a synonym: bind its parameters (by generic id) to the elaborated arguments and elaborate
-- its raw body under that binding, guarding against (mutual) recursion with 'visitingSynonyms'.
elaborateSynonym :: QualifiedName -> SynonymSignature -> List (SyntacticTypeExpression Identified) -> SourceSpan -> Elaborate (Maybe SemanticGenericArgument)
elaborateSynonym qualifiedName synonym arguments applicationSpan = do
  visiting <- asks (.visitingSynonyms)
  if Set.member qualifiedName visiting
    then Nothing <$ reportTypeError applicationSpan (TypeErrorSynonymCycle (SynonymCycleErrorInfo {name = qualifiedName}))
    else do
      maybeArguments <- elaborateArgumentList (renderQualifiedName qualifiedName) synonym.genericParameters arguments applicationSpan
      case maybeArguments of
        Nothing -> pure Nothing
        Just elaborated -> do
          let binding =
                Map.fromList
                  [ (info.genericId, argument)
                    | (name, info) <- Map.toList synonym.genericParameters.parameterInformation,
                      Just argument <- [Map.lookup name elaborated]
                  ]
          local
            ( \context ->
                context
                  { substitution = Map.union binding context.substitution,
                    visitingSynonyms = Set.insert qualifiedName context.visitingSynonyms
                  }
            )
            (elaborate synonym.body)

-- | Arity-check the positional arguments against the declared parameters, then elaborate each coerced
-- to its parameter's kind, keyed by parameter name (the form 'SemanticTypeData' / 'SemanticEffectRequest'
-- and a synonym binding all consume). 'parameterNames' supplies the order / keys; the per-name kind is
-- read from 'parameterInformation'. 'Nothing' only on an arity mismatch (already reported).
elaborateArgumentList :: Text -> GenericParameters -> List (SyntacticTypeExpression Identified) -> SourceSpan -> Elaborate (Maybe (Map Text SemanticGenericArgument))
elaborateArgumentList headLabel parameters arguments applicationSpan
  | length arguments /= length parameters.parameterNames =
      Nothing
        <$ reportTypeError
          applicationSpan
          (TypeErrorApplicationArity (ApplicationArityErrorInfo {head = headLabel, expected = length parameters.parameterNames, actual = length arguments}))
  | otherwise = Just . Map.fromList <$> zipWithM elaborateNamedArgument parameters.parameterNames arguments
  where
    elaborateNamedArgument name argument = do
      let kind = maybe GenericKindType (.kind) (Map.lookup name parameters.parameterInformation)
      coerced <- requireArgumentKind (sourceSpanOf argument) kind =<< elaborate argument
      pure (name, coerced)

-- | The @array@ / @record@ type constructors, applied to their one element type.
elaborateApplication :: TypeApplicationTypeNode Identified -> Elaborate (Maybe SemanticGenericArgument)
elaborateApplication node = case node.applicationHead of
  TypeName nameNode -> elaborateNameApplied nameNode node.applicationArguments node.sourceSpan
  TypeArray _ -> elaborateUnaryConstructor "array" SemanticTypeArray node.applicationArguments node.sourceSpan
  TypeRecord _ -> elaborateUnaryConstructor "record" SemanticTypeRecord node.applicationArguments node.sourceSpan
  _ -> Nothing <$ reportMalformed node.sourceSpan "This type cannot be applied to type arguments"

-- | A type constructor taking exactly one type argument (@array[T]@, @record[V]@).
elaborateUnaryConstructor :: Text -> (SemanticType -> SemanticType) -> List (SyntacticTypeExpression Identified) -> SourceSpan -> Elaborate (Maybe SemanticGenericArgument)
elaborateUnaryConstructor headLabel construct arguments applicationSpan = case arguments of
  [itemExpression] -> do
    itemType <- elaborateAsType itemExpression
    pureType (construct itemType)
  _ ->
    Nothing
      <$ reportTypeError
        applicationSpan
        (TypeErrorApplicationArity (ApplicationArityErrorInfo {head = headLabel, expected = 1, actual = length arguments}))
