-- | Constraint branching for the Solver.
--
-- When the decomposer is stuck on a constraint of the form
--
--   * @α \<: composite@ — type var on the left, composite (function /
--     array / tuple / object) on the right; or
--   * @composite \<: α@ — symmetric;
--   * @t \<: (B | C)@ — RHS union of two non-trivial branches;
--
-- we cannot make progress purely by structural decomposition. Instead, we
-- fan out into multiple alternative subgoals: pick fresh sub-vars to "narrow"
-- the variable's shape, OR commit the variable to 'never' / 'unknown'.
--
-- 'branchConstraint' returns a list of alternative branches. Each branch is
-- a triple @(subst, newConstraints, nextTypeVarId)@: the variable
-- assignment, additional constraints to satisfy, and the updated TypeVar
-- counter (since branching may allocate fresh vars).
--
-- 'branchConstraints' picks the first branchable constraint in the worklist
-- and fans it out, leaving the rest of the constraints untouched.
module Katari.Typechecker.Solver.Branch
  ( BranchAlt (..),
    branchConstraint,
    branchConstraints,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.SemanticType
  ( EffectVarId (..),
    SemanticEffect (..),
    SemanticType (..),
    TypeVarId (..),
    Unresolved,
  )
import Katari.Typechecker.Solver.Internal
  ( Substitution,
    typeVarsIn,
  )

-- ===========================================================================
-- BranchAlt
-- ===========================================================================

-- | One alternative produced by branching: the partial substitution to
-- apply, the additional constraints to satisfy, and the updated counters
-- for fresh-var allocation (both type and effect).
data BranchAlt = BranchAlt
  { branchSubst :: !Substitution,
    branchNewConstraints :: ![Constraint],
    branchNextTypeVarId :: !Int,
    branchNextEffectVarId :: !Int
  }
  deriving (Show)

-- ===========================================================================
-- branchConstraint
-- ===========================================================================

-- | Branch a single constraint into one or more alternatives. Returns
-- 'Nothing' if the constraint is not branchable (the solver should
-- continue with bound aggregation / final-substitution collection).
--
-- The two 'Int' parameters are the next free TypeVarId / EffectVarId
-- counters; each branch may allocate fresh vars and updates them
-- accordingly.
branchConstraint :: Int -> Int -> Constraint -> Maybe [BranchAlt]
branchConstraint nextTypeVarId nextEffectVarId = \case
  TypeConstraint leftType rightType reason ->
    branchType nextTypeVarId nextEffectVarId leftType rightType reason
  EffectConstraint {} -> Nothing

branchType ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Maybe [BranchAlt]
branchType nextTypeVarId nextEffectVarId leftType rightType reason =
  case (leftType, rightType) of
    -- α <: B | C : try α <: B OR α <: C.
    -- Only branch when LHS contains a type variable; if LHS is concrete the
    -- decomposer already settled or rejected this constraint via subtypeNT.
    (_, SemanticTypeUnion branches)
      | not (Set.null (typeVarsIn leftType)) ->
          Just
            [ BranchAlt
                { branchSubst = Map.empty,
                  branchNewConstraints = [TypeConstraint leftType branch reason],
                  branchNextTypeVarId = nextTypeVarId,
                  branchNextEffectVarId = nextEffectVarId
                }
              | branch <- branches
            ]
    -- α <: composite (LHS is var, RHS has structure).
    (SemanticTypeVariable typeVarId, _)
      | isBranchableShape rightType ->
          Just
            ( branchVarOnLeft nextTypeVarId nextEffectVarId typeVarId rightType reason
            )
    -- composite <: α (RHS is var, LHS has structure).
    (_, SemanticTypeVariable typeVarId)
      | isBranchableShape leftType ->
          Just
            ( branchVarOnRight nextTypeVarId nextEffectVarId leftType typeVarId reason
            )
    _ -> Nothing

-- | True iff the shape has internal structure that warrants branching.
-- Primitives, literals, and bare data refs don't need branching — bound
-- aggregation handles them.
isBranchableShape :: SemanticType Unresolved -> Bool
isBranchableShape = \case
  SemanticTypeFunction {} -> True
  SemanticTypeArray _ -> True
  SemanticTypeTuple _ -> True
  SemanticTypeObject _ -> True
  _ -> False

-- ---------------------------------------------------------------------------
-- α <: composite
-- ---------------------------------------------------------------------------

branchVarOnLeft ::
  Int ->
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnLeft nextTypeVarId nextEffectVarId typeVarId shape reason =
  let (narrowedShape, freshConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter) =
        narrowAsLeft nextTypeVarId nextEffectVarId typeVarId shape reason
   in [ -- Branch 1: α takes the structural shape with fresh sub-vars.
        BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVarId = nextTypeVarIdAfter,
            branchNextEffectVarId = nextEffectVarIdAfter
          },
        -- Branch 2: α is never (vacuously satisfies α <: anything).
        BranchAlt
          { branchSubst = Map.singleton typeVarId SemanticTypeNever,
            branchNewConstraints = [],
            branchNextTypeVarId = nextTypeVarId,
            branchNextEffectVarId = nextEffectVarId
          }
      ]

-- | Build a fresh-var "shape skeleton" for @α@ matching the right-hand
-- composite, plus the constraints that capture the variance:
-- contravariant for function args, covariant for return / array / tuple /
-- object fields. For function shapes, also allocate a fresh 'EffectVarId'.
narrowAsLeft ::
  Int ->
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, [Constraint], Int, Int)
narrowAsLeft nextTypeVarId nextEffectVarId _alpha shape reason = case shape of
  SemanticTypeFunction parameters returnType effects ->
    let parameterEntries = Map.toList parameters
        (parameterVars, nextAfterParams) = freshVars nextTypeVarId (length parameterEntries)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        (effectVar, nextEffectAfter) = freshEffectVar nextEffectVarId
        narrowedParameters =
          Map.fromList
            [ (label, SemanticTypeVariable parameterVar)
              | ((label, _), parameterVar) <- zip parameterEntries parameterVars
            ]
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (SemanticEffect (Set.singleton effectVar) Set.empty)
        parameterConstraints =
          -- contravariant: A <: t_arg
          [ TypeConstraint originalParameter (SemanticTypeVariable parameterVar) reason
            | ((_, originalParameter), parameterVar) <- zip parameterEntries parameterVars
          ]
        returnConstraint =
          TypeConstraint (SemanticTypeVariable returnVar) returnType reason
        effectConstraint =
          EffectConstraint
            (SemanticEffect (Set.singleton effectVar) Set.empty)
            effects
            reason
     in ( narrowedShape,
          effectConstraint : returnConstraint : parameterConstraints,
          nextAfterReturn,
          nextEffectAfter
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVarId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          TypeConstraint (SemanticTypeVariable elementVar) element reason -- covariant
     in (narrowedShape, [elementConstraint], nextAfterElement, nextEffectVarId)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVarId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ TypeConstraint (SemanticTypeVariable elementVar) originalElement reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, elementConstraints, nextAfterElements, nextEffectVarId)
  SemanticTypeObject fields ->
    let (fieldVars, nextAfterFields) = freshVars nextTypeVarId (Map.size fields)
        fieldLabels = Map.keys fields
        narrowedFields =
          Map.fromList (zip fieldLabels (SemanticTypeVariable <$> fieldVars))
        narrowedShape = SemanticTypeObject narrowedFields
        fieldConstraints =
          [ TypeConstraint (SemanticTypeVariable fieldVar) originalField reason
            | (fieldVar, originalField) <- zip fieldVars (Map.elems fields)
          ]
     in (narrowedShape, fieldConstraints, nextAfterFields, nextEffectVarId)
  _ -> (shape, [], nextTypeVarId, nextEffectVarId)
  -- shouldn't happen given isBranchableShape guard

-- ---------------------------------------------------------------------------
-- composite <: α
-- ---------------------------------------------------------------------------

branchVarOnRight ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  TypeVarId ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnRight nextTypeVarId nextEffectVarId shape typeVarId reason =
  let (narrowedShape, freshConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter) =
        narrowAsRight nextTypeVarId nextEffectVarId typeVarId shape reason
   in [ -- Branch 1: α takes the structural shape with fresh sub-vars.
        BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVarId = nextTypeVarIdAfter,
            branchNextEffectVarId = nextEffectVarIdAfter
          },
        -- Branch 2: α is unknown (vacuously satisfies anything <: α).
        BranchAlt
          { branchSubst = Map.singleton typeVarId SemanticTypeUnknown,
            branchNewConstraints = [],
            branchNextTypeVarId = nextTypeVarId,
            branchNextEffectVarId = nextEffectVarId
          }
      ]

narrowAsRight ::
  Int ->
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, [Constraint], Int, Int)
narrowAsRight nextTypeVarId nextEffectVarId _alpha shape reason = case shape of
  SemanticTypeFunction parameters returnType effects ->
    let parameterEntries = Map.toList parameters
        (parameterVars, nextAfterParams) = freshVars nextTypeVarId (length parameterEntries)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        (effectVar, nextEffectAfter) = freshEffectVar nextEffectVarId
        narrowedParameters =
          Map.fromList
            [ (label, SemanticTypeVariable parameterVar)
              | ((label, _), parameterVar) <- zip parameterEntries parameterVars
            ]
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (SemanticEffect (Set.singleton effectVar) Set.empty)
        parameterConstraints =
          -- contravariant: t_arg <: A
          [ TypeConstraint (SemanticTypeVariable parameterVar) originalParameter reason
            | ((_, originalParameter), parameterVar) <- zip parameterEntries parameterVars
          ]
        returnConstraint =
          TypeConstraint returnType (SemanticTypeVariable returnVar) reason
        effectConstraint =
          EffectConstraint
            effects
            (SemanticEffect (Set.singleton effectVar) Set.empty)
            reason
     in ( narrowedShape,
          effectConstraint : returnConstraint : parameterConstraints,
          nextAfterReturn,
          nextEffectAfter
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVarId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          TypeConstraint element (SemanticTypeVariable elementVar) reason -- covariant
     in (narrowedShape, [elementConstraint], nextAfterElement, nextEffectVarId)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVarId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ TypeConstraint originalElement (SemanticTypeVariable elementVar) reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, elementConstraints, nextAfterElements, nextEffectVarId)
  SemanticTypeObject fields ->
    let (fieldVars, nextAfterFields) = freshVars nextTypeVarId (Map.size fields)
        fieldLabels = Map.keys fields
        narrowedFields =
          Map.fromList (zip fieldLabels (SemanticTypeVariable <$> fieldVars))
        narrowedShape = SemanticTypeObject narrowedFields
        fieldConstraints =
          [ TypeConstraint originalField (SemanticTypeVariable fieldVar) reason
            | (fieldVar, originalField) <- zip fieldVars (Map.elems fields)
          ]
     in (narrowedShape, fieldConstraints, nextAfterFields, nextEffectVarId)
  _ -> (shape, [], nextTypeVarId, nextEffectVarId)

-- ---------------------------------------------------------------------------
-- Fresh var allocation
-- ---------------------------------------------------------------------------

freshVar :: Int -> (TypeVarId, Int)
freshVar nextTypeVarId = (TypeVarId nextTypeVarId, nextTypeVarId + 1)

freshEffectVar :: Int -> (EffectVarId, Int)
freshEffectVar nextEffectVarId = (EffectVarId nextEffectVarId, nextEffectVarId + 1)

freshVars :: Int -> Int -> ([TypeVarId], Int)
freshVars nextTypeVarId 0 = ([], nextTypeVarId)
freshVars nextTypeVarId count =
  let (typeVarId, nextAfterFirst) = freshVar nextTypeVarId
      (remaining, nextAfterAll) = freshVars nextAfterFirst (count - 1)
   in (typeVarId : remaining, nextAfterAll)

-- ===========================================================================
-- branchConstraints
-- ===========================================================================

-- | Find the first branchable constraint in the list and fan it out.
-- Returns 'Nothing' if no constraint is branchable.
--
-- Each result is @(subst, newConstraintList, nextTypeVarId, nextEffectVarId)@:
-- the alt's substitution, the worklist after the branch (remaining
-- constraints + new sub-constraints, with the substitution applied), and
-- the updated counters.
branchConstraints ::
  Int ->
  Int ->
  [Constraint] ->
  Maybe [(Substitution, [Constraint], Int, Int)]
branchConstraints nextTypeVarId nextEffectVarId constraints =
  case findFirstBranch nextTypeVarId nextEffectVarId constraints [] of
    Nothing -> Nothing
    Just (alternatives, untouched) ->
      Just
        [ ( alternative.branchSubst,
            alternative.branchNewConstraints <> untouched,
            alternative.branchNextTypeVarId,
            alternative.branchNextEffectVarId
          )
          | alternative <- alternatives
        ]

findFirstBranch ::
  Int ->
  Int ->
  [Constraint] ->
  [Constraint] ->
  Maybe ([BranchAlt], [Constraint])
findFirstBranch _ _ [] _ = Nothing
findFirstBranch nextTypeVarId nextEffectVarId (current : remaining) skipped =
  case branchConstraint nextTypeVarId nextEffectVarId current of
    Just alternatives ->
      Just (alternatives, reverse skipped <> remaining)
    Nothing ->
      findFirstBranch nextTypeVarId nextEffectVarId remaining (current : skipped)

-- Avoid unused-import warning on Text.
_typeText :: Text -> Text
_typeText = id
