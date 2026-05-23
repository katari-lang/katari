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
import Data.Text qualified as T
import Katari.SemanticType
  ( SemanticType (..),
    Unresolved,
  )
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.NormalizedType
  ( normaliseSemantic,
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
  Constraint ->
  Either SolverError (Set Constraint)
decomposeConstraint constraint = case constraint of
  -- Request constraints are handled separately; pass through.
  RequestConstraint {} -> Right (Set.singleton constraint)
  TypeConstraint leftType rightType reason ->
    decomposeType constraint leftType rightType reason

decomposeType ::
  Constraint ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Either SolverError (Set Constraint)
decomposeType original leftType rightType reason = case (leftType, rightType) of
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
        if subtypeNormalizedType (normaliseSemantic leftConcrete) (normaliseSemantic rightConcrete)
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
    )
      | Map.keysSet leftParameters == Map.keysSet rightParameters ->
          -- Args contravariant; return covariant; request covariant (subset).
          -- Parameters are matched by label (named-parameter calling
          -- convention): for each label L, derive @rightParameter \<: leftParameter@.
          let parameterConstraints =
                [ TypeConstraint rightParameter leftParameter reason
                  | (label, leftParameter) <- Map.toList leftParameters,
                    Just rightParameter <- [Map.lookup label rightParameters]
                ]
              returnConstraint = TypeConstraint leftReturn rightReturn reason
              requestConstraint = RequestConstraint leftRequests rightRequests reason
           in yield (requestConstraint : returnConstraint : parameterConstraints)
      | otherwise ->
          Left
            ( SolverErrorStructuralMismatch
                reason
                ( "function signature mismatch: "
                    <> showLabels leftParameters
                    <> " vs "
                    <> showLabels rightParameters
                )
            )
  (SemanticTypeArray leftElement, SemanticTypeArray rightElement) ->
    yield [TypeConstraint leftElement rightElement reason] -- covariant
  (SemanticTypeTuple leftElements, SemanticTypeTuple rightElements)
    | length leftElements == length rightElements ->
        yield
          ( zipWith
              (\leftElement rightElement -> TypeConstraint leftElement rightElement reason)
              leftElements
              rightElements
          )
    | otherwise ->
        Left
          ( SolverErrorStructuralMismatch
              reason
              ( "tuple arity mismatch: "
                  <> tshow (length leftElements)
                  <> " vs "
                  <> tshow (length rightElements)
              )
          )
  (SemanticTypeObject leftFields, SemanticTypeObject rightFields) ->
    decomposeObject leftFields rightFields reason
  (SemanticTypeData leftTypeId, SemanticTypeData rightTypeId)
    | leftTypeId == rightTypeId -> settled
    | otherwise ->
        Left
          ( SolverErrorContradiction
              reason
              (SemanticTypeData leftTypeId)
              (SemanticTypeData rightTypeId)
          )
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
  SemanticTypeBoolean -> Just "boolean"
  SemanticTypeLiteralBoolean _ -> Just "boolean"
  SemanticTypeFunction {} -> Just "function"
  SemanticTypeFunctionAny -> Just "function"
  SemanticTypeArray _ -> Just "array"
  SemanticTypeTuple _ -> Just "tuple"
  SemanticTypeObject _ -> Just "object"
  SemanticTypeData _ -> Just "data"
  -- Special forms (handled by earlier cases) intentionally fall through.
  SemanticTypeVariable _ -> Nothing
  SemanticTypeUnion _ -> Nothing
  SemanticTypeNever -> Nothing
  SemanticTypeUnknown -> Nothing

showLabels :: Map.Map Text (SemanticType phase) -> Text
showLabels parameters =
  "{" <> T.intercalate ", " (Map.keys parameters) <> "}"

decomposeObject ::
  Map.Map Text (SemanticType Unresolved) ->
  Map.Map Text (SemanticType Unresolved) ->
  ConstraintReason ->
  Either SolverError (Set Constraint)
decomposeObject leftFields rightFields reason =
  let missing = Map.keysSet rightFields `Set.difference` Map.keysSet leftFields
   in if not (Set.null missing)
        then
          Left
            ( SolverErrorStructuralMismatch
                reason
                ( "object missing required field(s): "
                    <> T.intercalate ", " (Set.toList missing)
                )
            )
        else
          Right $
            Set.fromList
              [ TypeConstraint leftFieldType rightFieldType reason
                | (label, rightFieldType) <- Map.toList rightFields,
                  Just leftFieldType <- [Map.lookup label leftFields]
              ]

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ===========================================================================
-- decomposeConstraintsAll
-- ===========================================================================

-- | Iterate single-step decomposition until the constraint set stabilises.
-- Each step replaces every constraint by its 'decomposeConstraint' result
-- (the original itself if not yet decomposable, otherwise its structural
-- sub-constraints), then re-runs until a fixpoint is reached. On any
-- 'Left', short-circuit and propagate the error.
decomposeConstraintsAll ::
  Set Constraint ->
  Either SolverError (Set Constraint)
decomposeConstraintsAll = go
  where
    go constraints = do
      stepped <- traverse decomposeConstraint (Set.toList constraints)
      let next = Set.unions stepped
      if next == constraints
        then pure constraints
        else go next
