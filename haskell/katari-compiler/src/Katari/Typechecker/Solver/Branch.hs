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
  ( SemanticEffect (..),
    SemanticType (..),
    TypeVarId (..),
    Unresolved,
  )
import Katari.Typechecker.Solver.Internal
  ( Substitution,
  )

-- ===========================================================================
-- BranchAlt
-- ===========================================================================

-- | One alternative produced by branching: the partial substitution to
-- apply, the additional constraints to satisfy, and the updated TypeVar
-- counter (after fresh var allocation, if any).
data BranchAlt = BranchAlt
  { branchSubst :: !Substitution,
    branchNewConstraints :: ![Constraint],
    branchNextTypeVarId :: !Int
  }
  deriving (Show)

-- ===========================================================================
-- branchConstraint
-- ===========================================================================

-- | Branch a single constraint into one or more alternatives. Returns
-- 'Nothing' if the constraint is not branchable (the solver should
-- continue with bound aggregation / final-substitution collection).
--
-- The 'Int' parameter is the next free TypeVarId counter; each branch may
-- allocate fresh vars and updates the counter accordingly.
branchConstraint :: Int -> Constraint -> Maybe [BranchAlt]
branchConstraint nextTypeVarId = \case
  TypeConstraint leftType rightType reason ->
    branchType nextTypeVarId leftType rightType reason
  EffectConstraint {} -> Nothing

branchType ::
  Int ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Maybe [BranchAlt]
branchType nextTypeVarId leftType rightType reason = case (leftType, rightType) of
  -- α <: B | C : try α <: B OR α <: C.
  (_, SemanticTypeUnion branches) ->
    Just
      [ BranchAlt
          { branchSubst = Map.empty,
            branchNewConstraints = [TypeConstraint leftType branch reason],
            branchNextTypeVarId = nextTypeVarId
          }
        | branch <- branches
      ]
  -- α <: composite (LHS is var, RHS has structure).
  (SemanticTypeVariable typeVarId, _)
    | isBranchableShape rightType ->
        Just (branchVarOnLeft nextTypeVarId typeVarId rightType reason)
  -- composite <: α (RHS is var, LHS has structure).
  (_, SemanticTypeVariable typeVarId)
    | isBranchableShape leftType ->
        Just (branchVarOnRight nextTypeVarId leftType typeVarId reason)
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
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnLeft nextTypeVarId typeVarId shape reason =
  let (narrowedShape, freshConstraints, nextTypeVarIdAfter) =
        narrowAsLeft nextTypeVarId typeVarId shape reason
   in [ -- Branch 1: α takes the structural shape with fresh sub-vars.
        BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVarId = nextTypeVarIdAfter
          },
        -- Branch 2: α is never (vacuously satisfies α <: anything).
        BranchAlt
          { branchSubst = Map.singleton typeVarId SemanticTypeNever,
            branchNewConstraints = [],
            branchNextTypeVarId = nextTypeVarId
          }
      ]

-- | Build a fresh-var "shape skeleton" for @α@ matching the right-hand
-- composite, plus the constraints that capture the variance:
-- contravariant for function args, covariant for return / array / tuple /
-- object fields.
narrowAsLeft ::
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, [Constraint], Int)
narrowAsLeft nextTypeVarId _alpha shape reason = case shape of
  SemanticTypeFunction parameters returnType effects ->
    let (parameterVars, nextAfterParams) = freshVars nextTypeVarId (length parameters)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        narrowedParameters =
          zipWith
            (\(label, _) parameterVar -> (label, SemanticTypeVariable parameterVar))
            parameters
            parameterVars
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (SemanticEffect Set.empty Set.empty)
        parameterConstraints =
          -- contravariant: A <: t_arg
          [ TypeConstraint originalParameter (SemanticTypeVariable parameterVar) reason
            | ((_, originalParameter), parameterVar) <- zip parameters parameterVars
          ]
        returnConstraint =
          TypeConstraint (SemanticTypeVariable returnVar) returnType reason
        effectConstraint =
          EffectConstraint (SemanticEffect Set.empty Set.empty) effects reason
     in ( narrowedShape,
          effectConstraint : returnConstraint : parameterConstraints,
          nextAfterReturn
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVarId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          TypeConstraint (SemanticTypeVariable elementVar) element reason -- covariant
     in (narrowedShape, [elementConstraint], nextAfterElement)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVarId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ TypeConstraint (SemanticTypeVariable elementVar) originalElement reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, elementConstraints, nextAfterElements)
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
     in (narrowedShape, fieldConstraints, nextAfterFields)
  _ -> (shape, [], nextTypeVarId) -- shouldn't happen given isBranchableShape guard

-- ---------------------------------------------------------------------------
-- composite <: α
-- ---------------------------------------------------------------------------

branchVarOnRight ::
  Int ->
  SemanticType Unresolved ->
  TypeVarId ->
  ConstraintReason ->
  [BranchAlt]
branchVarOnRight nextTypeVarId shape typeVarId reason =
  let (narrowedShape, freshConstraints, nextTypeVarIdAfter) =
        narrowAsRight nextTypeVarId typeVarId shape reason
   in [ -- Branch 1: α takes the structural shape with fresh sub-vars.
        BranchAlt
          { branchSubst = Map.singleton typeVarId narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVarId = nextTypeVarIdAfter
          },
        -- Branch 2: α is unknown (vacuously satisfies anything <: α).
        BranchAlt
          { branchSubst = Map.singleton typeVarId SemanticTypeUnknown,
            branchNewConstraints = [],
            branchNextTypeVarId = nextTypeVarId
          }
      ]

narrowAsRight ::
  Int ->
  TypeVarId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, [Constraint], Int)
narrowAsRight nextTypeVarId _alpha shape reason = case shape of
  SemanticTypeFunction parameters returnType effects ->
    let (parameterVars, nextAfterParams) = freshVars nextTypeVarId (length parameters)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        narrowedParameters =
          zipWith
            (\(label, _) parameterVar -> (label, SemanticTypeVariable parameterVar))
            parameters
            parameterVars
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (SemanticEffect Set.empty Set.empty)
        parameterConstraints =
          -- contravariant: t_arg <: A
          [ TypeConstraint (SemanticTypeVariable parameterVar) originalParameter reason
            | ((_, originalParameter), parameterVar) <- zip parameters parameterVars
          ]
        returnConstraint =
          TypeConstraint returnType (SemanticTypeVariable returnVar) reason
        effectConstraint =
          EffectConstraint effects (SemanticEffect Set.empty Set.empty) reason
     in ( narrowedShape,
          effectConstraint : returnConstraint : parameterConstraints,
          nextAfterReturn
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVarId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          TypeConstraint element (SemanticTypeVariable elementVar) reason -- covariant
     in (narrowedShape, [elementConstraint], nextAfterElement)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVarId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ TypeConstraint originalElement (SemanticTypeVariable elementVar) reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, elementConstraints, nextAfterElements)
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
     in (narrowedShape, fieldConstraints, nextAfterFields)
  _ -> (shape, [], nextTypeVarId)

-- ---------------------------------------------------------------------------
-- Fresh var allocation
-- ---------------------------------------------------------------------------

freshVar :: Int -> (TypeVarId, Int)
freshVar nextTypeVarId = (TypeVarId nextTypeVarId, nextTypeVarId + 1)

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
-- Each result is @(subst, newConstraintList, nextTypeVarId)@ — the alt's
-- substitution, the worklist after the branch (remaining constraints +
-- new sub-constraints, with the substitution applied), and the updated
-- TypeVar counter.
branchConstraints ::
  Int ->
  [Constraint] ->
  Maybe [(Substitution, [Constraint], Int)]
branchConstraints nextTypeVarId constraints =
  case findFirstBranch nextTypeVarId constraints [] of
    Nothing -> Nothing
    Just (alternatives, untouched) ->
      Just
        [ ( alternative.branchSubst,
            alternative.branchNewConstraints <> untouched,
            alternative.branchNextTypeVarId
          )
          | alternative <- alternatives
        ]

findFirstBranch ::
  Int ->
  [Constraint] ->
  [Constraint] ->
  Maybe ([BranchAlt], [Constraint])
findFirstBranch _ [] _ = Nothing
findFirstBranch nextTypeVarId (current : remaining) skipped =
  case branchConstraint nextTypeVarId current of
    Just alternatives ->
      Just (alternatives, reverse skipped <> remaining)
    Nothing ->
      findFirstBranch nextTypeVarId remaining (current : skipped)

-- Avoid unused-import warning on Text.
_typeText :: Text -> Text
_typeText = id
