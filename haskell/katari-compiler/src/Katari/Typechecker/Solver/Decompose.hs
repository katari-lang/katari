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
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.SemanticType
  ( SemanticEffect (..),
    SemanticType (..),
    Unresolved,
  )
import Katari.Typechecker.Solver.Internal
  ( SolverError (..),
    containsNoTypeVars,
    isSubtypeConcrete,
    semanticToConcrete,
  )

-- ===========================================================================
-- decomposeConstraint
-- ===========================================================================

-- | Single-step decomposition.
--
-- Returns @Right (settled, leftover)@:
--
--   * @settled@ — constraints discharged at this step (typically empty
--     when decomposition produced sub-constraints; the original is
--     "consumed").
--   * @leftover@ — constraints needing further processing: irreducible
--     leaves ("var vs anything") plus newly-generated sub-constraints
--     from structural decomposition.
--
-- Returns 'Left' on a hard contradiction (concrete-vs-concrete subtype
-- failure or structural mismatch).
decomposeConstraint ::
  Constraint ->
  Either SolverError ([Constraint], [Constraint])
decomposeConstraint constraint = case constraint of
  EffectConstraint {} ->
    -- Effect constraints are handled separately; pass through.
    Right ([], [constraint])
  TypeConstraint leftType rightType reason ->
    decomposeType constraint leftType rightType reason

decomposeType ::
  Constraint ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Either SolverError ([Constraint], [Constraint])
decomposeType original leftType rightType reason = case (leftType, rightType) of
  -- Trivial cases
  _ | leftType == rightType -> settled
  (SemanticTypeNever, _) -> settled
  (_, SemanticTypeUnknown) -> settled
  -- LHS or RHS is a type variable: leave for branching / bound aggregation.
  (SemanticTypeVariable _, _) -> remain
  (_, SemanticTypeVariable _) -> remain
  -- Both concrete (no vars): direct subtype check via NormalizedType.
  _
    | containsNoTypeVars leftType && containsNoTypeVars rightType ->
        if isSubtypeConcrete leftType rightType
          then settled
          else
            Left
              ( SolverErrorContradiction
                  reason
                  (resolvedOr SemanticTypeUnknown leftType)
                  (resolvedOr SemanticTypeUnknown rightType)
              )
  -- Structural decomposition.
  (SemanticTypeUnion branches, _) ->
    -- (A | B) <: C  →  A <: C  AND  B <: C
    yieldNew [TypeConstraint branch rightType reason | branch <- branches]
  (_, SemanticTypeUnion _) ->
    -- A <: (B | C): branching required (handled in Solver/Branch.hs).
    remain
  ( SemanticTypeFunction leftParameters leftReturn leftEffects,
    SemanticTypeFunction rightParameters rightReturn rightEffects
    )
      | matchSignature leftParameters rightParameters ->
          -- Args contravariant; return covariant; effect covariant (subset).
          let parameterConstraints =
                [ TypeConstraint rightParameter leftParameter reason
                  | ( (_, leftParameter),
                      (_, rightParameter)
                      ) <-
                      zip leftParameters rightParameters
                ]
              returnConstraint = TypeConstraint leftReturn rightReturn reason
              effectConstraint = EffectConstraint leftEffects rightEffects reason
           in yieldNew (effectConstraint : returnConstraint : parameterConstraints)
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
    yieldNew [TypeConstraint leftElement rightElement reason] -- covariant
  (SemanticTypeTuple leftElements, SemanticTypeTuple rightElements)
    | length leftElements == length rightElements ->
        yieldNew
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
  -- Other composites (e.g., function vs array) where one side might still
  -- contain a var: hand off to branching / bound aggregation.
  _ -> remain
  where
    settled = Right ([original], [])
    remain = Right ([], [original])
    yieldNew newConstraints = Right ([], newConstraints)

matchSignature ::
  [(Text, SemanticType phase)] ->
  [(Text, SemanticType phase)] ->
  Bool
matchSignature leftParameters rightParameters =
  length leftParameters == length rightParameters
    && and (zipWith sameLabel leftParameters rightParameters)
  where
    sameLabel (leftLabel, _) (rightLabel, _) = leftLabel == rightLabel

showLabels :: [(Text, SemanticType phase)] -> Text
showLabels parameters =
  "(" <> T.intercalate ", " (fst <$> parameters) <> ")"

decomposeObject ::
  Map.Map Text (SemanticType Unresolved) ->
  Map.Map Text (SemanticType Unresolved) ->
  ConstraintReason ->
  Either SolverError ([Constraint], [Constraint])
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
          let derivedConstraints =
                [ TypeConstraint leftFieldType rightFieldType reason
                  | (label, rightFieldType) <- Map.toList rightFields,
                    Just leftFieldType <- [Map.lookup label leftFields]
                ]
           in Right ([], derivedConstraints)

resolvedOr ::
  SemanticType targetPhase ->
  SemanticType Unresolved ->
  SemanticType targetPhase
resolvedOr fallback semanticType = case semanticToConcrete semanticType of
  Just resolved -> coerceToPhase resolved
  Nothing -> fallback
  where
    coerceToPhase :: SemanticType source -> SemanticType target
    coerceToPhase = \case
      SemanticTypeVariable _ ->
        -- SemanticTypeVariable only inhabits Unresolved; semanticToConcrete
        -- already filtered it out. Defensive: treat as Never.
        SemanticTypeNever
      SemanticTypeNever -> SemanticTypeNever
      SemanticTypeUnknown -> SemanticTypeUnknown
      SemanticTypeNull -> SemanticTypeNull
      SemanticTypeInteger -> SemanticTypeInteger
      SemanticTypeNumber -> SemanticTypeNumber
      SemanticTypeString -> SemanticTypeString
      SemanticTypeBoolean -> SemanticTypeBoolean
      SemanticTypeLiteralInteger value -> SemanticTypeLiteralInteger value
      SemanticTypeLiteralString value -> SemanticTypeLiteralString value
      SemanticTypeLiteralBoolean value -> SemanticTypeLiteralBoolean value
      SemanticTypeData typeId -> SemanticTypeData typeId
      SemanticTypeArray element -> SemanticTypeArray (coerceToPhase element)
      SemanticTypeTuple elements -> SemanticTypeTuple (coerceToPhase <$> elements)
      SemanticTypeUnion branches -> SemanticTypeUnion (coerceToPhase <$> branches)
      SemanticTypeObject fields -> SemanticTypeObject (Map.map coerceToPhase fields)
      SemanticTypeFunction parameterTypes returnType effects ->
        SemanticTypeFunction
          [ (label, coerceToPhase parameterType)
            | (label, parameterType) <- parameterTypes
          ]
          (coerceToPhase returnType)
          (SemanticEffect effects.effectVars effects.effectReqs)

tshow :: (Show a) => a -> Text
tshow = T.pack . show

-- ===========================================================================
-- decomposeConstraintsAll
-- ===========================================================================

-- | Iterate single-step decomposition until the leftover list stabilises.
-- Returns the union of all settled + leftover constraints (deduplicated by
-- equality). On any 'Left', short-circuit and propagate the error.
decomposeConstraintsAll ::
  [Constraint] ->
  Either SolverError [Constraint]
decomposeConstraintsAll = go
  where
    go constraints = do
      stepped <- traverse decomposeConstraint constraints
      let settled = concatMap fst stepped
          leftover = concatMap snd stepped
          combined = deduplicate (settled <> leftover)
      if sameSet combined constraints
        then pure combined
        else go combined

deduplicate :: (Eq a) => [a] -> [a]
deduplicate =
  foldr
    (\element accumulator -> if element `elem` accumulator then accumulator else element : accumulator)
    []

sameSet :: (Eq a) => [a] -> [a] -> Bool
sameSet leftSet rightSet =
  all (`elem` rightSet) leftSet && all (`elem` leftSet) rightSet
