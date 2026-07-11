-- | Local generic-argument inference for application sites (the /propose/ half of "inference
-- proposes, checking disposes"). This module is deliberately kept SEPARATE from 'subtype': the
-- trusted, authoritative relation in "Katari.Typechecker.Normalizer" is never modified or made
-- metavariable-aware. Instead the inference here is a distinct, approximate, error-free pass that only
-- collects candidate bounds for inference variables (metavariables); correctness is established later
-- by substituting the solution into the original scheme and running the ordinary 'subtype'.
--
-- Why the split: a metavariable's solution is provisional and need not be canonical. Under shadowing
-- (an effect tail's @lacks@ overrides, nested/shadowed generics, world-dependent attributes) a
-- metavariable has no unique standalone representation, so the only sound way to verify a candidate is
-- to substitute it in and let the trusted relation re-normalise the context. Hence 'collectConstraints'
-- (propose) records bounds without ever reporting, 'solveConstraints' picks a candidate, and the caller
-- substitutes + disposes via 'subtype'.
--
-- v1 scope: TYPE metavariables are inferred from the structural match of an argument against a
-- parameter type. Effect / attribute metavariables (rare; a scheme quantified over an effect /
-- attribute) collect no constraints here and so report as un-inferrable — the user supplies them
-- explicitly. This is enough for the two motivating cases (operators desugared to generic primitives,
-- and user generic agents whose type parameters appear in their value arguments).
module Katari.Typechecker.Inference where

import Control.Monad (foldM)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import GHC.List (List)
import Katari.Data.Environment (DataInformation (..), GenericParameterInformation (..), GenericParameters (..), RequestInformation (..))
import Katari.Data.GenericKind (GenericKind (..))
import Katari.Data.Id (GenericId)
import Katari.Data.NormalizedType
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.Variance (Variance (..))
import Katari.Typechecker.Normalizer
  ( Normalizer,
    alignObjectFields,
    alignSequenceItems,
    captureErrors,
    dataInfoFor,
    relateAtVariance,
    requestInfoFor,
    requestRowVariance,
    substituteEffect,
    substituteGenericArgument,
    substituteType,
    subtypeArgumentsWith,
    union,
  )

------------------------------------------------------------------------------------------------
-- Inference variables (metavariables)
------------------------------------------------------------------------------------------------

-- | One inference variable: the declared name it stands for (for diagnostics), its kind, and its
-- declared @extends@ upper bound (already rewritten into metavariable terms, so a bound that mentions
-- a sibling generic mentions the sibling's metavariable). The bound is consulted only at the dispose
-- step ('checkSolvedBounds') and as a recovery value for an un-inferrable variable.
data Metavar = Metavar
  { name :: Text,
    kind :: GenericKind,
    -- | Whether the declared parameter was marked @literal@ — the call site then proposes a string
    -- literal argument's singleton type for this variable ('Katari.Typechecker.Check.proposedLiteralArguments').
    bindsLiteral :: Bool,
    bound :: Maybe NormalizedKindedType
  }
  deriving (Eq, Show)

-- | The metavariables in scope for one application's inference, keyed by their fresh 'GenericId'.
type Registry = Map GenericId Metavar

-- | The bare metavariable of a given kind, as a normalized argument — what a scheme's generic
-- parameter is instantiated to. A type metavariable is the @never@ base carrying just the variable;
-- an effect metavariable is a single unbounded tail; an attribute metavariable is a public attribute
-- carrying just the variable. These mirror the scheme-variable forms the elaborator builds, but are
-- constructed directly here to keep this module free of the elaborator.
metavarKinded :: GenericKind -> GenericId -> NormalizedKindedType
metavarKinded kind metavar = case kind of
  GenericKindType ->
    NormalizedKindedTypeType
      NormalizedType {baseType = NormalizedBaseTypeLayered neverLayer, generics = Set.singleton metavar, attribute = bottomAttribute}
  GenericKindEffect ->
    NormalizedKindedTypeEffect (singleTailEffect metavar)
  GenericKindAttribute ->
    NormalizedKindedTypeAttribute NormalizedAttribute {private = False, generic = Set.singleton metavar}

------------------------------------------------------------------------------------------------
-- Constraints
------------------------------------------------------------------------------------------------

-- | The lower bounds collected for the metavariables of each kind. A lower bound comes from a value
-- flowing INTO a variable (the variable appears as a supertype: @actual <: M@); the covariant solution
-- is the join of the lowers. Only lowers are collected: a variable reached solely through a
-- contravariant position has none and is reported un-inferrable (K3016) for the user to supply
-- explicitly — the v1 inference is from the structural match of an argument against a parameter, which
-- only ever bounds a variable from below.
data Constraints = Constraints
  { typeBounds :: Map GenericId (List NormalizedType),
    effectBounds :: Map GenericId (List EffectLowerBound),
    attributeBounds :: Map GenericId (List NormalizedAttribute)
  }
  deriving (Eq, Show)

-- | One lower bound proposed for an effect metavariable, kept in a form whose variance-directed
-- concrete-request subtraction is DEFERRED to solve time. @effect@ is the raw continuation effect;
-- @subtractConcrete@ is the concrete requests the provider supplies (the @scope[URL] | ...@ part of its
-- continuation row), whose args may still mention type metavariables (a literal-bound @scope[URL]@);
-- @lacks@ is the parameter tail's own overwrite @lacks@. Deferring matters because a provider's
-- @scope[URL]@ is keyed on an as-yet-unsolved @URL@: only once the type metavariables are solved (from
-- the sibling @url@ argument) can @scope["a" | "b"]@ minus the now-known @scope["b"]@ reduce to
-- @scope["a"]@. See 'resolveEffectLowerBound'.
data EffectLowerBound = EffectLowerBound
  { effect :: NormalizedEffect,
    subtractConcrete :: Map QualifiedName (Map Text NormalizedKindedType),
    lacks :: Set QualifiedName
  }
  deriving (Eq, Show)

instance Semigroup Constraints where
  left <> right =
    Constraints
      { typeBounds = Map.unionWith (<>) left.typeBounds right.typeBounds,
        effectBounds = Map.unionWith (<>) left.effectBounds right.effectBounds,
        attributeBounds = Map.unionWith (<>) left.attributeBounds right.attributeBounds
      }

instance Monoid Constraints where
  mempty = Constraints {typeBounds = mempty, effectBounds = mempty, attributeBounds = mempty}

lowerType :: GenericId -> NormalizedType -> Constraints
lowerType metavar normalizedType = mempty {typeBounds = Map.singleton metavar [normalizedType]}

-- | A bare (no concrete-request subtraction) effect lower bound — the whole actual flows into the
-- variable, as a bare effect metavariable on the parameter side takes it.
lowerEffect :: GenericId -> NormalizedEffect -> Constraints
lowerEffect metavar effect = lowerEffectBound metavar EffectLowerBound {effect = effect, subtractConcrete = mempty, lacks = mempty}

lowerEffectBound :: GenericId -> EffectLowerBound -> Constraints
lowerEffectBound metavar bound = mempty {effectBounds = Map.singleton metavar [bound]}

lowerAttribute :: GenericId -> NormalizedAttribute -> Constraints
lowerAttribute metavar attribute = mempty {attributeBounds = Map.singleton metavar [attribute]}

------------------------------------------------------------------------------------------------
-- Propose: collect constraints by a variance-directed structural match
------------------------------------------------------------------------------------------------

-- | Whether a type is exactly a bare flexible metavariable (@never@ base, a single flexible generic,
-- no attribute) — the form 'metavarKinded' produces. Only this canonical shape is treated as an
-- inference leaf; any richer type is matched structurally instead, and an unmatched leaf simply
-- contributes no constraint (the dispose step will reject a genuine mismatch).
asTypeMetavar :: Set GenericId -> NormalizedType -> Maybe GenericId
asTypeMetavar flexible normalizedType = case normalizedType.baseType of
  NormalizedBaseTypeLayered layer
    | layer == neverLayer,
      [metavar] <- Set.toList normalizedType.generics,
      metavar `Set.member` flexible,
      normalizedType.attribute == bottomAttribute ->
        Just metavar
  _ -> Nothing

-- | Whether an effect is exactly a bare flexible effect metavariable (no concrete requests, a single
-- flexible tail with no overrides) — the form 'metavarKinded' produces for an effect generic.
asEffectMetavar :: Set GenericId -> NormalizedEffect -> Maybe GenericId
asEffectMetavar flexible effect
  | Map.null effect.exits,
    Map.null effect.continues,
    -- A bare metavariable is genuinely io-free (the shape 'singleTailEffect' builds, io = False). Excluding
    -- io here keeps this exact: an @{E, io}@ parameter is matched structurally and its io is enforced by the
    -- dispose-step subtype check, never silently absorbed into the metavar's lower bound.
    not effect.io,
    RequestEffectRow row <- effect.requests,
    Map.null row.request,
    [(metavar, lacks)] <- Map.toList row.tails,
    Set.null lacks,
    metavar `Set.member` flexible =
      Just metavar
  | otherwise = Nothing

-- | Whether an attribute is exactly a bare flexible attribute metavariable (public, a single flexible
-- generic) — the form 'metavarKinded' produces for an attribute generic.
asAttributeMetavar :: Set GenericId -> NormalizedAttribute -> Maybe GenericId
asAttributeMetavar flexible attribute
  | not attribute.private,
    [metavar] <- Set.toList attribute.generic,
    metavar `Set.member` flexible =
      Just metavar
  | otherwise = Nothing

-- | Collect the constraints under which @actual <: parameter@ could hold for an effect (the covariant
-- effect of a function). A bare effect metavariable on the parameter side takes the actual as a lower
-- bound. A parameter effect row carrying a flexible /tail/ alongside concrete requests — the @E |
-- scope[url]@ a scoped provider's continuation has, or the @{...E, req}@ a handler's continuation has —
-- gives that tail the actual with the row's concrete requests SUBTRACTED, so a provider's residual @E@
-- is inferred as the continuation's effect minus what the provider itself supplies concretely.
--
-- The subtraction is variance-directed per concrete entry, not a blanket name-drop ('subtractConcreteRequests'):
--
--   * an actual request the parameter's concrete entry fully subsumes (same name, the actual's args fit
--     the parameter's) is DISCHARGED — dropped from the residual. This is the cancellation rule: for the
--     agreeing @E | scope["u"] <: E2 | scope["u"]@ case it drops @scope["u"]@ and solves @E2 := E@
--     directly, rather than the old spelling's @E2 := E \\ scope@ (which the dispose then spuriously
--     rejected against a rigid @E@).
--   * a partially-covered entry — a wider covariant arg, e.g. a merged @scope["a" | "b"]@ against the
--     parameter's @scope["b"]@ — keeps its UNCOVERED remainder (@scope["a"]@) in the residual, so an
--     outer provider still sees the scope it must discharge. This is the name-keyed arg-union of nested
--     provides, handled at arg granularity.
--   * an actual request the parameter does not name is kept as-is.
--
-- The parameter tail's own overwrite @lacks@ (the @{...E, req}@ spelling) are still applied by NAME to
-- the actual's tails — that is what removes a request hiding inside the actual's own tail, which no
-- concrete-part subtraction could see. The actual's escape channels and io ride through untouched, so a
-- continuation's escapes flow into the solved @E@ and are discharged later at their target boundary.
--
-- SOUNDNESS: this is the error-free PROPOSE step; the trusted 'subtype' re-checks the solution at
-- dispose. Cancelling a covered entry (instead of blanket-subtracting it into the tail's @lacks@) can
-- only make the proposed residual LARGER — never smaller — than the old name-keyed subtraction, and a
-- larger covariant lower bound is the sound direction: if it is too large the dispose's result / bound
-- check rejects it, whereas the old over-subtraction made the residual too SMALL and the dispose then
-- rejected a valid @E | scope[url]@ continuation as "overrides incompatible". The subtraction itself is
-- carried on the 'EffectLowerBound' and run at SOLVE time ('resolveEffectLowerBound'), so a provider's
-- @scope[URL]@ is subtracted only after @URL@ is solved from the sibling @url@ argument.
collectEffectConstraints :: Set GenericId -> NormalizedEffect -> NormalizedEffect -> Constraints
collectEffectConstraints flexible actual parameter
  | Just metavar <- asEffectMetavar flexible parameter = lowerEffect metavar actual
  | otherwise = case parameter.requests of
      RequestEffectAny -> mempty
      RequestEffectRow parameterRow ->
        let flexibleTails = [(metavar, lacks) | (metavar, lacks) <- Map.toList parameterRow.tails, metavar `Set.member` flexible]
         in mconcat
              [ lowerEffectBound metavar EffectLowerBound {effect = actual, subtractConcrete = parameterRow.request, lacks = lacks}
                | (metavar, lacks) <- flexibleTails
              ]

-- | Discharge one deferred effect lower bound with the (already solved) type substitution applied: the
-- provider's concrete requests are subtracted from the continuation's effect only now, so a literal
-- @scope[URL]@'s @URL@ is concrete. An @all@ actual has no representable restriction and passes through
-- (a sound over-approximation — the dispose step re-checks).
resolveEffectLowerBound :: Map GenericId NormalizedKindedType -> EffectLowerBound -> Normalizer NormalizedEffect
resolveEffectLowerBound typeSubstitution bound = do
  effect <- substituteEffect typeSubstitution bound.effect
  subtractConcrete <- traverse (traverse (substituteGenericArgument typeSubstitution)) bound.subtractConcrete
  case effect.requests of
    RequestEffectAny -> pure effect
    RequestEffectRow row -> do
      residualRequest <- subtractConcreteRequests subtractConcrete row.request
      pure effect {requests = RequestEffectRow row {request = residualRequest, tails = Map.map (Set.union bound.lacks) row.tails}}

-- | Subtract a parameter row's concrete requests from the actual's concrete requests, variance-directed
-- per entry (see 'collectEffectConstraints'): a matched request the actual's args fully fit the
-- parameter's is dropped (discharged); a partially-covered one keeps the uncovered remainder of its
-- covariant args; an actual request the parameter does not name is kept as-is.
subtractConcreteRequests ::
  Map QualifiedName (Map Text NormalizedKindedType) ->
  Map QualifiedName (Map Text NormalizedKindedType) ->
  Normalizer (Map QualifiedName (Map Text NormalizedKindedType))
subtractConcreteRequests parameterRequests =
  Map.foldrWithKey step (pure Map.empty)
  where
    step name actualArguments accumulate = do
      accumulated <- accumulate
      case Map.lookup name parameterRequests of
        Nothing -> pure (Map.insert name actualArguments accumulated)
        Just parameterArguments -> do
          maybeResidual <- subtractRequestEntry name actualArguments parameterArguments
          pure $ case maybeResidual of
            Nothing -> accumulated
            Just residualArguments -> Map.insert name residualArguments accumulated

-- | Subtract one matched request's parameter args from its actual args, using the request's declared
-- variances (via 'requestRowVariance', which pins a phantom marker's arg to covariant). Returns
-- 'Nothing' when the parameter's entry fully subsumes the actual's (the entry is discharged), else the
-- uncovered remainder. Coverage is decided with the trusted 'subtype' the dispose step uses, so
-- "discharged" here means exactly "the dispose would accept the actual's entry against the parameter's".
subtractRequestEntry :: QualifiedName -> Map Text NormalizedKindedType -> Map Text NormalizedKindedType -> Normalizer (Maybe (Map Text NormalizedKindedType))
subtractRequestEntry name actualArguments parameterArguments = do
  requestInfo <- requestInfoFor name
  let variances = requestRowVariance . (.variance) <$> requestInfo.genericParameters.parameterInformation
  (_, coverageErrors) <- captureErrors (subtypeArgumentsWith variances actualArguments parameterArguments)
  pure $
    if null coverageErrors
      then Nothing
      else Just (Map.mapWithKey (reduceArgument variances) actualArguments)
  where
    -- Only a covariant position can keep an uncovered remainder; an invariant / contravariant one is
    -- left as the actual wrote it (the dispose step is the authority on whether it is acceptable).
    reduceArgument variances argumentName actualArgument = case (Map.lookup argumentName variances, Map.lookup argumentName parameterArguments) of
      (Just Covariant, Just parameterArgument) -> subtractKinded actualArgument parameterArgument
      _ -> actualArgument

-- | The covariant "difference" of one kinded arg, used to keep a request entry's UNCOVERED remainder.
-- Only the type kind's string layer is reduced (the phantom scope-URL case, where the arg is a
-- string-literal singleton or a union); every other layer / kind is kept, a sound over-approximation
-- the dispose step re-checks.
subtractKinded :: NormalizedKindedType -> NormalizedKindedType -> NormalizedKindedType
subtractKinded actual parameter = case (actual, parameter) of
  (NormalizedKindedTypeType actualType, NormalizedKindedTypeType parameterType) -> NormalizedKindedTypeType (subtractType actualType parameterType)
  _ -> actual

-- | Reduce a covariant type arg by removing the literals the parameter's arg already covers. Keeps all
-- non-string structure (over-approximation); for the scope-URL case the arg is purely string literals,
-- so @scope["a" | "b"]@ against @scope["b"]@ reduces to @scope["a"]@ exactly.
subtractType :: NormalizedType -> NormalizedType -> NormalizedType
subtractType actual parameter = case (actual.baseType, parameter.baseType) of
  (NormalizedBaseTypeLayered actualLayer, NormalizedBaseTypeLayered parameterLayer) ->
    actual {baseType = NormalizedBaseTypeLayered actualLayer {stringLayer = stringSlotDifference actualLayer.stringLayer parameterLayer.stringLayer}}
  _ -> actual

-- | As 'collectEffectConstraints', for the attribute of a node (only the bare-metavariable shapes are
-- recognised; richer attributes contribute nothing and are left to the dispose check).
collectAttributeConstraints :: Set GenericId -> NormalizedAttribute -> NormalizedAttribute -> Constraints
collectAttributeConstraints flexible actual parameter
  | Just metavar <- asAttributeMetavar flexible parameter = lowerAttribute metavar actual
  | otherwise = mempty

-- | Collect the constraints under which @actual <: parameter@ could hold, recording a bound for every
-- flexible metavariable reached. This mirrors the structure of 'subtype' (function arguments are
-- contravariant, data arguments follow their declared variance) but RECORDS instead of CHECKS and
-- never reports a diagnostic. Anything it does not understand contributes 'mempty' — soundness is the
-- dispose step's job, not this pass's.
collectConstraints :: Set GenericId -> NormalizedType -> NormalizedType -> Normalizer Constraints
collectConstraints flexible = goType
  where
    goType actual parameter
      | Just metavar <- asTypeMetavar flexible parameter = pure (lowerType metavar actual)
      | otherwise = do
          -- A node also carries an attribute; collect any attribute-metavariable bound there too.
          let attributeConstraints = collectAttributeConstraints flexible actual.attribute parameter.attribute
          baseConstraints <- case (actual.baseType, parameter.baseType) of
            (NormalizedBaseTypeLayered actualLayer, NormalizedBaseTypeLayered parameterLayer) ->
              goLayers actualLayer parameterLayer
            _ -> pure mempty
          pure (attributeConstraints <> baseConstraints)
    goLayers actualLayer parameterLayer =
      mconcat
        <$> sequence
          [ goFunction actualLayer.functionLayer parameterLayer.functionLayer,
            goSequence actualLayer.sequenceLayer parameterLayer.sequenceLayer,
            goObject actualLayer.objectLayer parameterLayer.objectLayer,
            goData actualLayer.dataLayer parameterLayer.dataLayer
          ]
    goFunction (Just actualFunction) (Just parameterFunction) = do
      -- The argument is contravariant (swap), the return and effect covariant.
      argumentConstraints <- goType parameterFunction.argumentType actualFunction.argumentType
      returnConstraints <- goType actualFunction.returnType parameterFunction.returnType
      let effectConstraints = collectEffectConstraints flexible actualFunction.effect parameterFunction.effect
      pure (argumentConstraints <> returnConstraints <> effectConstraints)
    goFunction _ _ = pure mempty
    goSequence (Just actualSequence) (Just parameterSequence) = do
      itemConstraints <- traverse (uncurry goType) (alignSequenceItems actualSequence parameterSequence)
      restConstraints <- goType actualSequence.rest parameterSequence.rest
      pure (mconcat itemConstraints <> restConstraints)
    goSequence _ _ = pure mempty
    goObject (Just actualObject) (Just parameterObject) = do
      fieldConstraints <-
        traverse
          (\(actualField, parameterField) -> goType actualField.normalizedType parameterField.normalizedType)
          (Map.elems (alignObjectFields actualObject parameterObject))
      restConstraints <- goType actualObject.rest parameterObject.rest
      pure (mconcat fieldConstraints <> restConstraints)
    goObject _ _ = pure mempty
    goData actualData parameterData =
      mconcat <$> traverse perName (Map.toList (Map.intersectionWith (,) actualData parameterData))
      where
        perName (dataName, (actualArguments, parameterArguments)) = do
          info <- dataInfoFor dataName
          let variances = (.variance) <$> info.genericParameters.parameterInformation
          mconcat
            <$> traverse
              (perArgument variances)
              (Map.toList (Map.intersectionWith (,) actualArguments parameterArguments))
        -- The same variance discipline the subtype check uses ('relateAtVariance'), so propose and
        -- dispose agree on direction; an unmatched name is treated as unused (bivariant).
        perArgument variances (argumentName, (actualArgument, parameterArgument)) =
          relateAtVariance goKinded (Map.findWithDefault Bivariant argumentName variances) actualArgument parameterArgument
    goKinded (NormalizedKindedTypeType actual) (NormalizedKindedTypeType parameter) = goType actual parameter
    goKinded _ _ = pure mempty

------------------------------------------------------------------------------------------------
-- Solve
------------------------------------------------------------------------------------------------

-- | The provisional solution: a substitution from every metavariable to a chosen argument, plus the
-- metavariables that could not be inferred (no lower bound resolved them). Un-inferrable variables are
-- still given a recovery value in the substitution (their bound, or the kind's top) so downstream
-- checking does not cascade; the caller reports them (K3016).
data SolveResult = SolveResult
  { substitution :: Map GenericId NormalizedKindedType,
    uninferred :: List GenericId
  }
  deriving (Eq, Show)

-- | Every generic id mentioned anywhere inside a type (its own node, its attribute, and recursively
-- through every layer / effect / argument). Used to detect when a candidate still depends on an
-- as-yet-unsolved metavariable.
deepGenerics :: NormalizedType -> Set GenericId
deepGenerics normalizedType =
  Set.unions [normalizedType.generics, normalizedType.attribute.generic, baseGenerics normalizedType.baseType]
  where
    baseGenerics = \case
      NormalizedBaseTypeUnknown -> Set.empty
      NormalizedBaseTypeLayered layer -> layerGenerics layer
    layerGenerics layer =
      Set.unions
        [ maybe Set.empty functionGenerics layer.functionLayer,
          maybe Set.empty sequenceGenerics layer.sequenceLayer,
          maybe Set.empty objectGenerics layer.objectLayer,
          Set.unions [kindedGenerics argument | arguments <- Map.elems layer.dataLayer, argument <- Map.elems arguments]
        ]
    functionGenerics function =
      Set.unions [deepGenerics function.argumentType, deepGenerics function.returnType, effectGenerics function.effect]
    sequenceGenerics normalizedSequence =
      Set.unions (deepGenerics normalizedSequence.rest : map deepGenerics normalizedSequence.items)
    objectGenerics normalizedObject =
      Set.unions (deepGenerics normalizedObject.rest : [deepGenerics field.normalizedType | field <- Map.elems normalizedObject.fields])
    effectGenerics effect =
      Set.unions $
        (deepGenerics <$> (Map.elems effect.exits <> Map.elems effect.continues))
          <> case effect.requests of
            RequestEffectAny -> []
            RequestEffectRow row ->
              Map.keysSet row.tails : [kindedGenerics argument | arguments <- Map.elems row.request, argument <- Map.elems arguments]
    kindedGenerics = \case
      NormalizedKindedTypeType normalizedType' -> deepGenerics normalizedType'
      NormalizedKindedTypeEffect effect -> effectGenerics effect
      NormalizedKindedTypeAttribute attribute -> attribute.generic

-- | Solve a metavariable registry against collected constraints. Every metavariable is solved to the
-- join of its lower bounds: type metavariables iterate to a fixpoint (a lower bound may mention another
-- metavariable, solved first); effect and attribute metavariables join directly (with already-solved
-- type metavariables substituted into their request arguments). Variables with no lower bound (or stuck
-- in a cycle) are reported un-inferrable and given a recovery value.
solveConstraints :: Registry -> Constraints -> Normalizer SolveResult
solveConstraints registry constraints = do
  let metavarsOfKind kind = [metavar | (metavar, info) <- Map.toList registry, info.kind == kind]
      typeMetavars = metavarsOfKind GenericKindType
      typeMetavarSet = Set.fromList typeMetavars
      typeLowersOf metavar = Map.findWithDefault [] metavar constraints.typeBounds
  solvedTypes <- fixpoint typeMetavarSet (length typeMetavars) typeLowersOf typeMetavars Map.empty
  let typeSubstitution = Map.map NormalizedKindedTypeType solvedTypes
  solvedEffects <- foldM (solveEffect typeSubstitution) Map.empty (metavarsOfKind GenericKindEffect)
  solvedAttributes <- foldM solveAttribute Map.empty (metavarsOfKind GenericKindAttribute)
  let solvedSubstitution = typeSubstitution <> solvedEffects <> solvedAttributes
      unresolved = [metavar | metavar <- Map.keys registry, not (Map.member metavar solvedSubstitution)]
  recoveries <- traverse (\metavar -> (,) metavar <$> recover solvedSubstitution metavar) unresolved
  pure
    SolveResult
      { substitution = solvedSubstitution <> Map.fromList recoveries,
        uninferred = unresolved
      }
  where
    solveEffect typeSubstitution solved metavar =
      case Map.findWithDefault [] metavar constraints.effectBounds of
        [] -> pure solved
        lowers -> do
          -- The type substitution is applied here, so a deferred concrete-request subtraction (a
          -- provider's @scope[URL]@) runs against a now-solved @URL@.
          resolved <- traverse (resolveEffectLowerBound typeSubstitution) lowers
          joined <- foldM union bottomEffect resolved
          pure (Map.insert metavar (NormalizedKindedTypeEffect joined) solved)
    solveAttribute solved metavar =
      case Map.findWithDefault [] metavar constraints.attributeBounds of
        [] -> pure solved
        lowers -> do
          joined <- foldM union bottomAttribute lowers
          pure (Map.insert metavar (NormalizedKindedTypeAttribute joined) solved)
    -- One round substitutes the already-solved type metavariables into each unsolved variable's lower
    -- bounds; a variable whose substituted lowers no longer mention an unsolved type metavariable is
    -- solved to their join. Repeats while progress is made, bounded by the variable count (no cycle
    -- loops). Only an unsolved /type/ metavariable blocks a solution — an effect / attribute
    -- metavariable is solved in its own later pass, so it must not hold a type variable back here.
    fixpoint typeMetavarSet fuel lowersOf metavars solved
      | fuel <= 0 = pure solved
      | otherwise = do
          (solved', changed) <- foldM (tryOne typeMetavarSet lowersOf) (solved, False) metavars
          if changed then fixpoint typeMetavarSet (fuel - 1) lowersOf metavars solved' else pure solved
    tryOne typeMetavarSet lowersOf (solved, changed) metavar
      | Map.member metavar solved = pure (solved, changed)
      | otherwise = case lowersOf metavar of
          [] -> pure (solved, changed)
          lowers -> do
            substituted <- traverse (substituteType (Map.map NormalizedKindedTypeType solved)) lowers
            let residual = Set.intersection typeMetavarSet (Set.unions (map deepGenerics substituted))
            if Set.null residual
              then do
                joined <- foldM union bottomType substituted
                pure (Map.insert metavar joined solved, True)
              else pure (solved, changed)
    recover solved metavar = case Map.lookup metavar registry of
      Just info -> case info.bound of
        Just bound -> substituteGenericArgument solved bound
        Nothing -> pure (kindTop info.kind)
      Nothing -> pure (NormalizedKindedTypeType topType)
    kindTop = \case
      GenericKindType -> NormalizedKindedTypeType topType
      GenericKindEffect -> NormalizedKindedTypeEffect topEffect
      GenericKindAttribute -> NormalizedKindedTypeAttribute topAttribute

-- NOTE: "inference proposes, checking disposes" — this module stops at the proposal ('solveConstraints').
-- The dispose step (checking the solution against each generic's declared @extends@ bound with the
-- trusted 'subtype') belongs to the checker, which runs it uniformly for inferred and explicit
-- application: see 'Katari.Typechecker.Check.checkInferredBounds' over the shared
-- 'Katari.Typechecker.Normalizer.checkBounds' loop.
