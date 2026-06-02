-- | Constraint decomposition for the Solver.
--
-- Given a constraint @t1 \<: t2@, decompose it into smaller constraints
-- when both sides have compatible composite shapes (function vs function,
-- array vs array, ...). When the constraint is a leaf — both sides
-- variable-free, or one side a bare type variable — leave it for the
-- subsequent stages (final-substitution collection, branching).
--
-- All derived constraints inherit the original 'ConstraintReason', so
-- error messages can trace back to the originating syntactic site.
module Katari.Typechecker.Solver.Decompose
  ( decomposeConstraint,
    decomposeConstraintsAll,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.SemanticType
  ( Parameter (..),
    SemanticType (..),
    Unresolved,
    liftResolvedToUnresolved,
  )
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.NormalizedType
  ( DataFieldEnv,
    denormalise,
    normaliseSemantic,
    subtypeNormalizedType,
  )
import Katari.Typechecker.Solver.Internal
  ( SolverError (..),
    semanticToConcrete,
  )

-- ===========================================================================
-- decomposeConstraint
-- ===========================================================================

-- | Single-step decomposition. Returns the set of constraints that replace
-- the input — either the original itself (when decomposition isn't
-- applicable yet, e.g. a stuck @var \<: composite@) or the structural
-- sub-constraints derived from the original. The caller iterates this until
-- the constraint set stabilises.
--
-- Returns 'Left' on a hard contradiction (concrete-vs-concrete subtype
-- failure or structural mismatch).
decomposeConstraint ::
  DataFieldEnv ->
  Constraint ->
  Either SolverError (Set Constraint)
decomposeConstraint env constraint = case constraint of
  -- Request constraints are handled separately; pass through.
  RequestConstraint {} -> Right (Set.singleton constraint)
  TypeConstraint leftType rightType reason ->
    decomposeType env constraint leftType rightType reason

decomposeType ::
  DataFieldEnv ->
  Constraint ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Either SolverError (Set Constraint)
decomposeType env original leftType rightType reason = case (leftType, rightType) of
  -- Trivial cases
  _ | leftType == rightType -> settled
  (SemanticTypeNever, _) -> settled
  (_, SemanticTypeUnknown) -> settled
  -- LHS or RHS is a type variable: leave for branching / bound aggregation.
  (SemanticTypeVariable _, _) -> keep
  (_, SemanticTypeVariable _) -> keep
  -- Both fully concrete (no type vars AND no request vars): direct subtype
  -- check via NormalizedType. We use 'semanticToConcrete' as the gate so
  -- that function types with unresolved request variables fall through to
  -- the structural decomposition cases below instead of being rejected here.
  _
    | Just leftConcrete <- semanticToConcrete leftType,
      Just rightConcrete <- semanticToConcrete rightType ->
        if subtypeNormalizedType env (normaliseSemantic leftConcrete) (normaliseSemantic rightConcrete)
          then settled
          else Left (SolverErrorContradiction reason leftConcrete rightConcrete)
  -- Structural decomposition.
  (SemanticTypeUnion branches, _) ->
    -- (A | B) <: C  →  A <: C  AND  B <: C
    yield [TypeConstraint branch rightType reason | branch <- branches]
  (_, SemanticTypeUnion _) ->
    -- A <: (B | C): branching required (handled in Solver/Branch.hs).
    keep
  ( SemanticTypeFunction leftParameters leftReturn leftRequests,
    SemanticTypeFunction rightParameters rightReturn rightRequests
    ) ->
      -- Width-subtyping on the label set: missing labels on either side
      -- are filled with 'SemanticTypeUnknown' (= top of the lattice),
      -- then the standard contravariant param / covariant return /
      -- covariant request decomposition runs over the union of labels.
      --
      -- Concretely: @f1 ⊑ f2@ where label sets differ becomes a check
      -- that each common label's RHS-param ⊑ LHS-param, plus the
      -- missing labels are checked against 'unknown' (vacuous for
      -- "missing on LHS", error-revealing for "missing on RHS where
      -- the LHS-param is concrete").
      --
      -- Optional exception: a label that is /optional/ on the LHS (the
      -- callee, in a @callee ⊑ {args}@ call constraint) and /absent/ on
      -- the RHS (the call site omitted it) generates no constraint — the
      -- omission is legal and the runtime fills the default. Without this
      -- the fill would emit @unknown ⊑ paramType@ and wrongly reject the
      -- omission.
      let allLabels = Map.keysSet leftParameters <> Map.keysSet rightParameters
          parameterTypeOf parameters label =
            maybe SemanticTypeUnknown (.parameterType) (Map.lookup label parameters)
          omittedOptional label =
            maybe False (.optional) (Map.lookup label leftParameters)
              && label `Map.notMember` rightParameters
          parameterConstraints =
            [ TypeConstraint
                (parameterTypeOf rightParameters label)
                (parameterTypeOf leftParameters label)
                reason
              | label <- Set.toList allLabels,
                not (omittedOptional label)
            ]
          returnConstraint = TypeConstraint leftReturn rightReturn reason
          requestConstraint = RequestConstraint leftRequests rightRequests reason
       in yield (requestConstraint : returnConstraint : parameterConstraints)
  (SemanticTypeArray leftElement, SemanticTypeArray rightElement) ->
    yield [TypeConstraint leftElement rightElement reason] -- covariant
  (SemanticTypeTuple leftElements, SemanticTypeTuple rightElements)
    -- Width-subtyping on positional length: a longer tuple refines a
    -- shorter prefix, so the LHS must have at least as many positions as
    -- the RHS. A shorter LHS is a hard failure — its missing positions may
    -- be absent at runtime, so they cannot be padded with 'unknown' (which
    -- would unsoundly accept @tuple[A] <: tuple[C, unknown]@). Extra LHS
    -- positions are dropped by 'zipWith' truncating at the RHS length.
    | length leftElements >= length rightElements ->
        yield
          [ TypeConstraint leftElement rightElement reason
            | (leftElement, rightElement) <- zip leftElements rightElements
          ]
    | otherwise ->
        Left
          ( SolverErrorStructuralMismatch
              reason
              "tuple has fewer positions than required"
          )
  (SemanticTypeObject leftFields, SemanticTypeObject rightFields) ->
    decomposeObject leftFields rightFields reason
  (SemanticTypeRecord leftValue, SemanticTypeRecord rightValue) ->
    -- record[V1] <: record[V2] iff V1 <: V2 (covariant on values).
    -- Keys are implicit @string@ on both sides so there is nothing
    -- to constrain.
    yield [TypeConstraint leftValue rightValue reason]
  (SemanticTypeData leftTypeId, SemanticTypeData rightTypeId)
    | leftTypeId == rightTypeId -> settled
    | otherwise ->
        Left
          ( SolverErrorContradiction
              reason
              (SemanticTypeData leftTypeId)
              (SemanticTypeData rightTypeId)
          )
  -- Cross-shape subtype edges of the unified lattice: a precise / nominal
  -- type is a subtype of its more-general counterpart, decomposed
  -- covariantly. Reached only when the constraint is not fully concrete
  -- (the concrete gate above already settled / rejected those via
  -- 'subtypeNormalizedType'); here one side still carries a variable. These
  -- MUST precede the shapeKind-mismatch rejection below — they connect
  -- otherwise-disjoint layer kinds (data↔object, object↔record, tuple↔array).
  (SemanticTypeData leftTypeId, SemanticTypeObject rightFields) ->
    -- data q <: {..}: expand q to its declared object view and run object
    -- width subtyping. Extra declared fields are dropped (vacuous via
    -- width); a field demanded by the RHS but absent on q surfaces as
    -- @unknown <: field@.
    decomposeObject (dataObjectView leftTypeId) rightFields reason
  (SemanticTypeData leftTypeId, SemanticTypeRecord rightValue) ->
    -- data q <: record[v]: every declared field of q must be <: v.
    yield
      [ TypeConstraint fieldType rightValue reason
        | fieldType <- Map.elems (dataObjectView leftTypeId)
      ]
  (SemanticTypeObject leftFields, SemanticTypeRecord rightValue) ->
    -- {..} <: record[v]: every field must be <: v.
    yield [TypeConstraint fieldType rightValue reason | fieldType <- Map.elems leftFields]
  (SemanticTypeTuple leftElements, SemanticTypeArray rightElement) ->
    -- [a, b, …] <: array[v]: every position must be <: v.
    yield [TypeConstraint element rightElement reason | element <- leftElements]
  -- Cross-shape rejection: when neither side is a bare variable / union /
  -- Never / Unknown (= all those are handled by the cases above) and the
  -- two shapes live in disjoint layers (e.g., integer vs object{foo: α},
  -- string vs array[β], function vs tuple), the constraint is
  -- unsatisfiable regardless of any inner variables. Without this case
  -- such constraints fell through to `_ -> keep`, were never picked up
  -- by `checkContradictions` (which only fires on fully-concrete pairs),
  -- and silently typechecked.
  _
    | Just leftKind <- shapeKind leftType,
      Just rightKind <- shapeKind rightType,
      leftKind /= rightKind ->
        Left
          ( SolverErrorStructuralMismatch
              reason
              ("shape mismatch: " <> leftKind <> " is not a subtype of " <> rightKind)
          )
  -- Other shapes where one side still contains a var and the layer kinds
  -- are compatible (e.g., function-vs-function with mismatched param
  -- labels already handled above; this catches functionAny vs function
  -- and similar bound-aggregation cases): hand off to branching.
  _ -> keep
  where
    settled = Right Set.empty
    keep = Right (Set.singleton original)
    yield newConstraints = Right (Set.fromList newConstraints)
    -- The declared field object of a 'data' as 'SemanticType Unresolved',
    -- reified from the (concrete) normalized fields the env carries. Empty
    -- for an unknown name (treated as a fieldless object = fails any field
    -- demand), which never happens for an in-scope data.
    dataObjectView typeId =
      liftResolvedToUnresolved . denormalise
        <$> Map.findWithDefault Map.empty typeId env

-- | Classify a 'SemanticType' by which NormalizedType layer it lives in.
-- Returns 'Nothing' for types whose layer is dynamic (variables, unions,
-- never / unknown) — those are handled by other decompose cases. The
-- classifier is conservative: when two non-'Nothing' kinds disagree,
-- the constraint is provably unsatisfiable.
shapeKind :: SemanticType Unresolved -> Maybe Text
shapeKind = \case
  SemanticTypeNull -> Just "null"
  SemanticTypeInteger -> Just "number"
  SemanticTypeNumber -> Just "number"
  SemanticTypeLiteralInteger _ -> Just "number"
  SemanticTypeString -> Just "string"
  SemanticTypeLiteralString _ -> Just "string"
  SemanticTypeSecret -> Just "secret"
  SemanticTypeFile -> Just "file"
  SemanticTypeBoolean -> Just "boolean"
  SemanticTypeLiteralBoolean _ -> Just "boolean"
  SemanticTypeFunction {} -> Just "function"
  SemanticTypeFunctionAny -> Just "function"
  SemanticTypeArray _ -> Just "array"
  SemanticTypeTuple _ -> Just "tuple"
  SemanticTypeObject _ -> Just "object"
  SemanticTypeData _ -> Just "data"
  SemanticTypeRecord _ -> Just "record"
  -- Special forms (handled by earlier cases) intentionally fall through.
  SemanticTypeVariable _ -> Nothing
  SemanticTypeUnion _ -> Nothing
  SemanticTypeNever -> Nothing
  SemanticTypeUnknown -> Nothing

decomposeObject ::
  Map.Map Text (SemanticType Unresolved) ->
  Map.Map Text (SemanticType Unresolved) ->
  ConstraintReason ->
  Either SolverError (Set Constraint)
decomposeObject leftFields rightFields reason =
  -- Width-subtyping, covariant: the LHS must carry every field the RHS
  -- demands. A field present on the RHS but absent on the LHS is a hard
  -- structural failure (the field may be absent at runtime) — it must NOT
  -- be deferred as @unknown ⊑ RHS_field@, which would let an RHS field
  -- variable widen to 'unknown' to "satisfy" the demand and unsoundly
  -- accept @{} <: {x: t}@. Extra LHS fields are dropped (accepted) by
  -- width.
  case filter (`Map.notMember` leftFields) (Map.keys rightFields) of
    (missingLabel : _) ->
      Left
        ( SolverErrorStructuralMismatch
            reason
            ("object is missing required field: " <> missingLabel)
        )
    [] ->
      Right $
        Set.fromList
          [ TypeConstraint leftFieldType rightFieldType reason
            | (label, rightFieldType) <- Map.toList rightFields,
              Just leftFieldType <- [Map.lookup label leftFields]
          ]

-- ===========================================================================
-- decomposeConstraintsAll
-- ===========================================================================

-- | Iterate single-step decomposition until the constraint set stabilises.
-- Each step replaces every constraint by its 'decomposeConstraint' result
-- (the original itself if not yet decomposable, otherwise its structural
-- sub-constraints), then re-runs until a fixpoint is reached. On any
-- 'Left', short-circuit and propagate the error.
decomposeConstraintsAll ::
  DataFieldEnv ->
  Set Constraint ->
  Either SolverError (Set Constraint)
decomposeConstraintsAll env = go
  where
    go constraints = do
      stepped <- traverse (decomposeConstraint env) (Set.toList constraints)
      let next = Set.unions stepped
      if next == constraints
        then pure constraints
        else go next
