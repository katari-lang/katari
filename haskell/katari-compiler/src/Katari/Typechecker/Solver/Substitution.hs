-- | Substitution composition utilities for the Solver.
--
-- This module supplies the bookkeeping for:
--
--   * Applying a 'Substitution' (Map TypeVariableId (SemanticType Unresolved))
--     to individual types and constraints.
--   * Composing substitutions (@outer ∘ inner@).
--   * Substituting resolved request sets into types (= the missing half
--     of "deep substitution composition" — needed so narrowed function
--     shapes don't keep their fresh request var alive after pinning).
--
-- Bound aggregation lives in 'Solver/Bounds.hs'; this module is purely
-- about substitution mechanics. Subtype check is implemented **only** on
-- 'NormalizedType' (see 'NormalizedType.subtypeNormalizedType') and used
-- through 'Solver/Bounds.hs' or 'Solver/Internal.hs::isSubtypeConcrete'.
module Katari.Typechecker.Solver.Substitution
  ( applySubstConstraint,
    applySubstSubst,
    applyRequestSubstToType,
  )
where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.Id (RequestId)
import Katari.SemanticType
  ( RequestVariableId,
    SemanticRequest (..),
    SemanticRequestElement (SemanticRequestElementConcrete),
    SemanticType (..),
    Unresolved,
    singletonRequestVariable,
    substituteVariable,
  )
import Katari.Typechecker.ConstraintGenerator (Constraint (..))
import Katari.Typechecker.Solver.Internal (Substitution)

-- ===========================================================================
-- Apply substitution
-- ===========================================================================

-- | Substitute every 'SemanticTypeVariable' that has an entry in the
-- substitution map. Variables without entries pass through unchanged.
--
-- The substitution maps to 'SemanticType' 'Unresolved' values, so this
-- function is naturally Unresolved-typed: variables that the substitution
-- itself still contains (transitive references) are left in place to be
-- substituted on a subsequent pass.
applySubstType :: Substitution -> SemanticType Unresolved -> SemanticType Unresolved
applySubstType substitution =
  runIdentity
    . substituteVariable
      (\typeVariableId -> Identity $ Map.findWithDefault (SemanticTypeVariable typeVariableId) typeVariableId substitution)
      (Identity . singletonRequestVariable)

-- | Resolve every 'RequestVariableId' inside a 'SemanticType' against the request
-- substitution, replacing each var with the concrete 'RequestId' set the
-- request solver assigned to it. Type variables are left untouched — apply
-- 'applySubstSubst' first if the value still contains them.
--
-- This is the missing half of "deep substitution composition": without it,
-- a narrowed function shape like @α := (x: t_p) -> r_var, eff e_var@ keeps
-- @e_var@ alive after type vars are pinned, and 'semanticToConcrete' rejects
-- the value (forcing the downstream to fall back to NormalizedTypeUnknown).
applyRequestSubstToType ::
  Map RequestVariableId (Set RequestId) ->
  SemanticType Unresolved ->
  SemanticType Unresolved
applyRequestSubstToType requestSubstitution =
  runIdentity
    . substituteVariable
      (Identity . SemanticTypeVariable)
      ( \requestVariableId ->
          Identity $ SemanticRequest $ Set.map SemanticRequestElementConcrete $ Map.findWithDefault Set.empty requestVariableId requestSubstitution
      )

applySubstRequest :: Substitution -> SemanticRequest phase -> SemanticRequest phase
applySubstRequest _ request = request -- request vars are handled by the request solver

applySubstConstraint :: Substitution -> Constraint -> Constraint
applySubstConstraint substitution = \case
  TypeConstraint leftType rightType reason ->
    TypeConstraint
      (applySubstType substitution leftType)
      (applySubstType substitution rightType)
      reason
  RequestConstraint leftRequest rightRequest reason ->
    RequestConstraint
      (applySubstRequest substitution leftRequest)
      (applySubstRequest substitution rightRequest)
      reason

-- | Apply @outer@ to every value in @inner@, then merge: @outer ∘ inner@.
applySubstSubst :: Substitution -> Substitution -> Substitution
applySubstSubst outer inner =
  Map.union (Map.map (applySubstType outer) inner) outer
