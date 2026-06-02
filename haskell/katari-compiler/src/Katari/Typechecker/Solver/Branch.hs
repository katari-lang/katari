{- HLINT ignore "Redundant bracket" -}

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
-- a 'BranchAlt' carrying the partial substitution, additional constraints
-- to satisfy, and the updated TypeVar / RequestVar counters (since
-- branching may allocate fresh vars).
module Katari.Typechecker.Solver.Branch
  ( BranchAlt (..),
    branchConstraint,
    isBranchableShape,
  )
where

import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.SemanticType
  ( Parameter (..),
    RequestVariableId (..),
    SemanticRequest (..),
    SemanticType (..),
    TypeVariableId (..),
    Unresolved,
    singletonRequestVariable,
  )
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintReason,
  )
import Katari.Typechecker.Solver.Internal
  ( Substitution,
    typeVarsIn,
  )

-- | Which side of a stuck @α \<: composite@ constraint α sits on. Drives the
-- variance of every sub-constraint emitted by 'narrowShape': swapping the
-- side flips both the @<:@ direction (covariant ↔ contravariant flip per
-- position) and the fallback assignment ('Never' for left-α; 'Unknown' for
-- right-α).
data BranchSide where
  LeftVar :: BranchSide
  RightVar :: BranchSide
  deriving (Eq, Show)

-- ===========================================================================
-- BranchAlt
-- ===========================================================================

-- | One alternative produced by branching: the partial substitution to
-- apply, the additional constraints to satisfy, and the updated counters
-- for fresh-var allocation (both type and request).
data BranchAlt = BranchAlt
  { branchSubst :: Substitution,
    branchNewConstraints :: (Set Constraint),
    branchNextTypeVariableId :: Int,
    branchNextRequestVariableId :: Int
  }
  deriving (Show)

-- ===========================================================================
-- branchConstraint
-- ===========================================================================

-- | Branch a single constraint into one or more alternatives. Returns
-- 'Nothing' if the constraint is not branchable (the solver should
-- continue with bound aggregation / final-substitution collection).
--
-- The two 'Int' parameters are the next free TypeVariableId / RequestVariableId
-- counters; each branch may allocate fresh vars and updates them
-- accordingly.
branchConstraint :: Int -> Int -> Constraint -> Maybe [BranchAlt]
branchConstraint nextTypeVariableId nextRequestVariableId = \case
  TypeConstraint leftType rightType reason ->
    branchType nextTypeVariableId nextRequestVariableId leftType rightType reason
  RequestConstraint {} -> Nothing

branchType ::
  Int ->
  Int ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Maybe [BranchAlt]
branchType nextTV nextRV leftType rightType reason =
  case (leftType, rightType) of
    -- α <: (B | C) where the union has internal vars (= not yet concrete).
    -- Required: pick one branch (= world fan-out). When B and C are both
    -- concrete, the bound-pair Solver loop aggregates the union as an
    -- upper bound via 'intersectNT' instead, so branching is not used
    -- and we avoid the union-return secret-taint bug (= committing
    -- prematurely to one element of the upper union).
    (_, SemanticTypeUnion branches)
      | not (Set.null (typeVarsIn leftType))
          && not (Set.null (typeVarsIn rightType)) ->
          Just
            [ BranchAlt
                { branchSubst = Map.empty,
                  branchNewConstraints =
                    Set.singleton (TypeConstraint leftType branch reason),
                  branchNextTypeVariableId = nextTV,
                  branchNextRequestVariableId = nextRV
                }
              | branch <- branches
            ]
    -- α <: composite (LHS is var, RHS has structure).
    (SemanticTypeVariable α, _)
      | isBranchableShape rightType ->
          Just (branchVar LeftVar nextTV nextRV α rightType reason)
    -- composite <: α (RHS is var, LHS has structure).
    (_, SemanticTypeVariable α)
      | isBranchableShape leftType ->
          Just (branchVar RightVar nextTV nextRV α leftType reason)
    _ -> Nothing

-- | True iff the shape has internal structure that warrants branching.
-- Primitives, literals, bare data refs, and the function top type
-- ('function') don't need branching — bound aggregation handles them.
isBranchableShape :: SemanticType Unresolved -> Bool
isBranchableShape = \case
  SemanticTypeFunction {} -> True
  SemanticTypeArray _ -> True
  SemanticTypeTuple _ -> True
  SemanticTypeObject _ -> True
  SemanticTypeRecord _ -> True
  -- 'function' (function-top) is treated as a primitive: it has no
  -- internal structure to branch on; the constraint goes straight to
  -- bound aggregation just like @α \<: integer@ or @integer \<: α@.
  SemanticTypeFunctionAny -> False
  _ -> False

-- ---------------------------------------------------------------------------
-- Variance-flipping helpers
-- ---------------------------------------------------------------------------

-- | Emit a constraint at a covariant position. \"Covariant\" means α-position
-- and original-position align with the @<:@ direction set by 'side': for
-- 'LeftVar' (α \<: F) the flow is @α-pos \<: F-pos@, and for 'RightVar' it
-- reverses.
emitCovariantType ::
  BranchSide ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Constraint
emitCovariantType side variableSide originalSide reason = case side of
  LeftVar -> TypeConstraint variableSide originalSide reason
  RightVar -> TypeConstraint originalSide variableSide reason

-- | Emit a constraint at a contravariant position (function parameters).
-- Same as 'emitCovariantType' but with the side flipped.
emitContravariantType ::
  BranchSide ->
  SemanticType Unresolved ->
  SemanticType Unresolved ->
  ConstraintReason ->
  Constraint
emitContravariantType side = emitCovariantType (flipSide side)

-- | Request-constraint counterpart of 'emitCovariantType'.
emitCovariantRequest ::
  BranchSide ->
  SemanticRequest Unresolved ->
  SemanticRequest Unresolved ->
  ConstraintReason ->
  Constraint
emitCovariantRequest side variableSide originalSide reason = case side of
  LeftVar -> RequestConstraint variableSide originalSide reason
  RightVar -> RequestConstraint originalSide variableSide reason

flipSide :: BranchSide -> BranchSide
flipSide = \case
  LeftVar -> RightVar
  RightVar -> LeftVar

-- ---------------------------------------------------------------------------
-- branchVar : narrow + fallback for both α \<: F and F \<: α
-- ---------------------------------------------------------------------------

-- | Two alternatives for a stuck @α \<: F@ or @F \<: α@:
--
--   1. α takes the structural shape with fresh sub-vars (variance constraints
--      are emitted via 'narrowShape').
--   2. α := 'SemanticTypeNever' (for 'LeftVar', vacuously @α \<: anything@) or
--      α := 'SemanticTypeFunctionAny' / 'SemanticTypeUnknown' (for 'RightVar',
--      vacuously @anything \<: α@).
--
-- The fallback is load-bearing: after substituting @α := Never@ (or
-- 'Unknown'), any existing concrete lower bound @T \<: α@ in the worklist
-- reduces to @T \<: Never@ on the next iteration, which fails the
-- concrete-vs-concrete subtype check and surfaces the error. Removing
-- the fallback silently masks signature mismatches that show up only
-- through bound aggregation cross-checks.
branchVar ::
  BranchSide ->
  Int ->
  Int ->
  TypeVariableId ->
  SemanticType Unresolved ->
  ConstraintReason ->
  [BranchAlt]
branchVar side nextTV nextRV α shape reason =
  let (narrowedShape, freshConstraints, nextTVAfter, nextRVAfter) =
        narrowShape side nextTV nextRV shape reason
      fallback = case side of
        LeftVar -> SemanticTypeNever
        RightVar -> case shape of
          SemanticTypeFunction {} -> SemanticTypeFunctionAny
          _ -> SemanticTypeUnknown
   in [ BranchAlt
          { branchSubst = Map.singleton α narrowedShape,
            branchNewConstraints = freshConstraints,
            branchNextTypeVariableId = nextTVAfter,
            branchNextRequestVariableId = nextRVAfter
          },
        BranchAlt
          { branchSubst = Map.singleton α fallback,
            branchNewConstraints = Set.empty,
            branchNextTypeVariableId = nextTV,
            branchNextRequestVariableId = nextRV
          }
      ]

-- | Build a fresh-var \"shape skeleton\" for α matching @shape@, plus the
-- variance-respecting sub-constraints. 'BranchSide' selects which side of
-- @<:@ α sits on, which flips every emitted constraint's direction.
--
-- For 'SemanticTypeFunction', a fresh 'RequestVariableId' is allocated and an
-- request constraint is added at the covariant position.
narrowShape ::
  BranchSide ->
  Int ->
  Int ->
  SemanticType Unresolved ->
  ConstraintReason ->
  (SemanticType Unresolved, Set Constraint, Int, Int)
narrowShape side nextTypeVariableId nextRequestVariableId shape reason = case shape of
  SemanticTypeFunction parameters returnType requests ->
    let parameterEntries = Map.toList parameters
        (parameterVars, nextAfterParams) = freshVars nextTypeVariableId (length parameterEntries)
        (returnVar, nextAfterReturn) = freshVar nextAfterParams
        (requestVar, nextRequestAfter) = freshRequestVar nextRequestVariableId
        narrowedParameters =
          Map.fromList
            [ (label, Parameter {parameterType = SemanticTypeVariable parameterVar, optional = originalParameter.optional})
              | ((label, originalParameter), parameterVar) <- zip parameterEntries parameterVars
            ]
        narrowedShape =
          SemanticTypeFunction
            narrowedParameters
            (SemanticTypeVariable returnVar)
            (singletonRequestVariable requestVar)
        parameterConstraints =
          [ emitContravariantType side (SemanticTypeVariable parameterVar) originalParameter.parameterType reason
            | ((_, originalParameter), parameterVar) <- zip parameterEntries parameterVars
          ]
        returnConstraint =
          emitCovariantType side (SemanticTypeVariable returnVar) returnType reason
        requestConstraint =
          emitCovariantRequest
            side
            (singletonRequestVariable requestVar)
            requests
            reason
     in ( narrowedShape,
          Set.fromList (requestConstraint : returnConstraint : parameterConstraints),
          nextAfterReturn,
          nextRequestAfter
        )
  SemanticTypeArray element ->
    let (elementVar, nextAfterElement) = freshVar nextTypeVariableId
        narrowedShape = SemanticTypeArray (SemanticTypeVariable elementVar)
        elementConstraint =
          emitCovariantType side (SemanticTypeVariable elementVar) element reason
     in (narrowedShape, Set.singleton elementConstraint, nextAfterElement, nextRequestVariableId)
  SemanticTypeTuple elements ->
    let (elementVars, nextAfterElements) = freshVars nextTypeVariableId (length elements)
        narrowedShape = SemanticTypeTuple (SemanticTypeVariable <$> elementVars)
        elementConstraints =
          [ emitCovariantType side (SemanticTypeVariable elementVar) originalElement reason
            | (elementVar, originalElement) <- zip elementVars elements
          ]
     in (narrowedShape, Set.fromList elementConstraints, nextAfterElements, nextRequestVariableId)
  SemanticTypeObject fields ->
    let (fieldVars, nextAfterFields) = freshVars nextTypeVariableId (Map.size fields)
        fieldLabels = Map.keys fields
        narrowedFields =
          Map.fromList (zip fieldLabels (SemanticTypeVariable <$> fieldVars))
        narrowedShape = SemanticTypeObject narrowedFields
        fieldConstraints =
          [ emitCovariantType side (SemanticTypeVariable fieldVar) originalField reason
            | (fieldVar, originalField) <- zip fieldVars (Map.elems fields)
          ]
     in (narrowedShape, Set.fromList fieldConstraints, nextAfterFields, nextRequestVariableId)
  SemanticTypeRecord valueType ->
    let (valueVar, nextAfterValue) = freshVar nextTypeVariableId
        narrowedShape = SemanticTypeRecord (SemanticTypeVariable valueVar)
        -- Values are covariant; the key type is implicit @string@ so
        -- it doesn't participate in the narrowed shape.
        valueConstraint =
          emitCovariantType side (SemanticTypeVariable valueVar) valueType reason
     in ( narrowedShape,
          Set.singleton valueConstraint,
          nextAfterValue,
          nextRequestVariableId
        )
  -- Defensive: 'isBranchableShape' guards the call site so this is unreachable.
  _ -> (shape, Set.empty, nextTypeVariableId, nextRequestVariableId)

-- ---------------------------------------------------------------------------
-- Fresh var allocation
-- ---------------------------------------------------------------------------

freshVar :: Int -> (TypeVariableId, Int)
freshVar nextTypeVariableId = (TypeVariableId nextTypeVariableId, nextTypeVariableId + 1)

freshRequestVar :: Int -> (RequestVariableId, Int)
freshRequestVar nextRequestVariableId = (RequestVariableId nextRequestVariableId, nextRequestVariableId + 1)

freshVars :: Int -> Int -> ([TypeVariableId], Int)
freshVars nextTypeVariableId 0 = ([], nextTypeVariableId)
freshVars nextTypeVariableId count =
  let (typeVarId, nextAfterFirst) = freshVar nextTypeVariableId
      (remaining, nextAfterAll) = freshVars nextAfterFirst (count - 1)
   in (typeVarId : remaining, nextAfterAll)
