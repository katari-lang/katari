-- | Typechecker phase 3: Solve constraints for type variables.
--
-- Input  : 'ConstraintGenResult' (the AST + constraints from phase 2).
-- Output : 'SolverResult' — substitutions for every type / effect variable
--          allocated in phase 2, plus a list of solver errors encountered
--          during recovery.
--
-- Algorithm (mirrors @memento-compiler@'s approach):
--
--   1. Partition constraints into type and effect.
--   2. Repeatedly substitute "instances" — variables whose lower / upper
--      bound intersection pins them to a concrete type.
--   3. Decompose structurally (function vs function, tuple vs tuple, ...).
--   4. If decomposition is stuck on a type-var-vs-composite combo, branch:
--      try "narrow var to that shape with fresh sub-vars" OR "var = never /
--      unknown".
--   5. Propagate bounds (from @t \<: α@ and @α \<: u@ derive @t \<: u@).
--   6. Collect final substitutions: each var = union of its lower bounds,
--      or sole upper bound if no lower bound is concrete.
--   7. Effect constraints are solved separately by lower-bound accumulation.
--
-- Subtype check is implemented **only** on 'NormalizedType'. Whenever we need
-- to compare two types, both sides must be variable-free — we then convert
-- via 'normaliseSemantic' and call 'subtypeNT'.
--
-- All metadata ('SourceSpan' / 'ConstraintReason') is propagated through
-- decomposition so error reports can point to the originating site.
module Katari.Typechecker.Solver
  ( -- * Result (re-exported from 'Solver.Internal')
    SolverResult (..),
    SolverError (..),

    -- * Internal types (re-exported)
    Substitution,
    BoundedType (..),
    Bounds (..),
    emptyBounds,

    -- * Helpers (re-exported)
    semanticToConcrete,
    isSubtypeConcrete,
    containsNoTypeVars,
    constraintTypeVars,
    typeVarsIn,
    effectVarsIn,
    partitionConstraints,
    isTypeConstraint,
    isEffectConstraint,

    -- * Entry
    solve,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Katari.AST (Position (..), SourceSpan (..))
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintGenResult (..),
    ConstraintReason (..),
  )
import Katari.Typechecker.Identifier (VariableId)
import Katari.Typechecker.NormalizedType
  ( NormalizedType (..),
    normaliseSemantic,
    subtypeNT,
  )
import Katari.Typechecker.SemanticType
  ( EffectVarId (..),
    TypeVarId (..),
  )
import Katari.Typechecker.Solver.Branch qualified as Branch
import Katari.Typechecker.Solver.Decompose qualified as Decompose
import Katari.Typechecker.Solver.Effect qualified as Effect
import Katari.Typechecker.Solver.Internal
import Katari.Typechecker.Solver.Substitution qualified as Substitution

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

solve :: ConstraintGenResult -> SolverResult
solve cgResult =
  let allConstraints = cgResult.constraints
      typeConstraints = filter isTypeConstraint allConstraints
      effectConstraints = filter isEffectConstraint allConstraints
      (typeSubstitution_, typeErrors) =
        solveTypeWorklist cgResult.nextTypeVarId cgResult.nextEffectVarId typeConstraints
      (effectSubstitution_, effectErrors) =
        solveEffectWorklist cgResult.nextEffectVarId effectConstraints
      normalizedTypeSubstitution = substToNormalizedSafe typeSubstitution_
   in SolverResult
        { typeSubstitution =
            totaliseTypes cgResult.nextTypeVarId normalizedTypeSubstitution,
          effectSubstitution =
            totaliseEffects cgResult.nextEffectVarId effectSubstitution_,
          solverErrors = typeErrors <> effectErrors
        }

-- ---------------------------------------------------------------------------
-- Type worklist
-- ---------------------------------------------------------------------------

-- | Top-level type-constraint solver loop. Returns the accumulated
-- substitution and any errors encountered. Errors short-circuit the loop;
-- the caller will fall back to NTUnknown for any unsolved variables.
solveTypeWorklist ::
  Int ->
  Int ->
  [Constraint] ->
  (Substitution, [SolverError])
solveTypeWorklist startNextTypeVarId startNextEffectVarId initialConstraints =
  case go startNextTypeVarId startNextEffectVarId initialConstraints Map.empty of
    Right substitution -> (substitution, [])
    Left err -> (Map.empty, [err])
  where
    go ::
      Int ->
      Int ->
      [Constraint] ->
      Substitution ->
      Either SolverError Substitution
    go nextTypeVarId nextEffectVarId constraints accumulatedSubstitution = do
      let substituted =
            fmap (Substitution.applySubstConstraint accumulatedSubstitution) constraints
      decomposed <- Decompose.decomposeConstraintsAll substituted
      let bounds = Substitution.calculateAllBounds decomposed
          pinnable =
            Map.toList (Map.mapMaybe Substitution.calculateInstanceFromBounds bounds)
      case pinnable of
        ((typeVarId, pinnedType) : _) ->
          let newSubstitution = Map.insert typeVarId pinnedType accumulatedSubstitution
           in go nextTypeVarId nextEffectVarId decomposed newSubstitution
        [] ->
          case Branch.branchConstraints nextTypeVarId nextEffectVarId decomposed of
            Just branches ->
              tryBranches nextTypeVarId nextEffectVarId accumulatedSubstitution branches
            Nothing -> do
              let propagated = Substitution.calculatePropagationAll decomposed
                  collected = Substitution.collectFinalSubstitutions propagated
                  finalSubstitution = Map.union collected accumulatedSubstitution
              case checkContradictions propagated of
                [] -> pure finalSubstitution
                (firstError : _) -> Left firstError

    tryBranches ::
      Int ->
      Int ->
      Substitution ->
      [(Substitution, [Constraint], Int, Int)] ->
      Either SolverError Substitution
    tryBranches _ _ _ [] =
      Left
        ( SolverErrorStructuralMismatch
            (synthesisedReason initialConstraints)
            "all branches failed"
        )
    tryBranches _ _ accumulatedSubstitution [(branchSubstitution, branchConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter)] = do
      let combinedSubstitution = Map.union branchSubstitution accumulatedSubstitution
      go nextTypeVarIdAfter nextEffectVarIdAfter branchConstraints combinedSubstitution
    tryBranches nextTypeVarId nextEffectVarId accumulatedSubstitution ((branchSubstitution, branchConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter) : remainingBranches) =
      let combinedSubstitution = Map.union branchSubstitution accumulatedSubstitution
       in case go nextTypeVarIdAfter nextEffectVarIdAfter branchConstraints combinedSubstitution of
            Right successSubstitution -> Right successSubstitution
            Left _ ->
              tryBranches
                nextTypeVarId
                nextEffectVarId
                accumulatedSubstitution
                remainingBranches

-- | Detect concrete-vs-concrete contradictions in remaining constraints
-- after propagation.
checkContradictions :: [Constraint] -> [SolverError]
checkContradictions = foldr collect []
  where
    collect (TypeConstraint leftType rightType reason) accumulator
      | Just leftConcrete <- semanticToConcrete leftType,
        Just rightConcrete <- semanticToConcrete rightType,
        not (subtypeNT (normaliseSemantic leftConcrete) (normaliseSemantic rightConcrete)) =
          SolverErrorContradiction reason leftConcrete rightConcrete : accumulator
    collect _ accumulator = accumulator

-- | Pick a 'ConstraintReason' to attach to a synthesised solver error
-- ("all branches failed"): use the reason of the first constraint that
-- still mentions a type variable (most likely the syntactic origin of
-- the unresolvable constraint), falling back to a dummy span if no such
-- constraint exists.
synthesisedReason :: [Constraint] -> ConstraintReason
synthesisedReason constraints =
  case [reason | TypeConstraint _ _ reason <- constraints] of
    (firstReason : _) -> ReasonSolverInternal (extractSpan firstReason)
    [] -> ReasonSolverInternal dummySpan
  where
    dummySpan =
      SrcSpan
        { filePath = "",
          start = Position {line = 0, column = 0},
          end = Position {line = 0, column = 0}
        }

extractSpan :: ConstraintReason -> SourceSpan
extractSpan = \case
  ReasonAgentSignature s -> s
  ReasonRequestSignature s -> s
  ReasonExternalAgentSignature s -> s
  ReasonDataConstructorSignature s -> s
  ReasonRequestHandlerSignature s -> s
  ReasonReturnTypeAnnotation s -> s
  ReasonReturnStatement s -> s
  ReasonImplicitReturn s -> s
  ReasonEffectBound s -> s
  ReasonHandleEffectDischarge s -> s
  ReasonHandlerEffectBound s -> s
  ReasonHandleNext s -> s
  ReasonHandleImplicitBreak s -> s
  ReasonHandleBreak s -> s
  ReasonHandleResultBody s -> s
  ReasonThenPattern s -> s
  ReasonThenBodyToOuter s -> s
  ReasonThenBodyToWhole s -> s
  ReasonForBreak s -> s
  ReasonForIn s -> s
  ReasonModifierUpdate s -> s
  ReasonLetPattern s -> s
  ReasonStateVarAnnotation s -> s
  ReasonForVarAnnotation s -> s
  ReasonVariablePatternAnnotation s -> s
  ReasonCallArgument s -> s
  ReasonBinaryOperator s -> s
  ReasonUnaryOperator s -> s
  ReasonIfCondition s -> s
  ReasonIfBranch s -> s
  ReasonMatchSubject s -> s
  ReasonMatchArm s -> s
  ReasonFieldAccess s -> s
  ReasonIndexAccessArray s -> s
  ReasonIndexAccessIndex s -> s
  ReasonTemplateInterpolation s -> s
  ReasonArrayElement s -> s
  ReasonConstructorPattern s -> s
  ReasonSolverInternal s -> s

-- | Convert each pinned 'SemanticType' 'Unresolved' to the public
-- 'NormalizedType' form. Variables that are still unresolved post-solve
-- (defensive case — should not normally happen) fall back to 'NTUnknown',
-- the lattice top, so that downstream phases treat them as "any" rather
-- than "never".
substToNormalizedSafe :: Substitution -> Map TypeVarId NormalizedType
substToNormalizedSafe = Map.map convert
  where
    convert pinnedType = case semanticToConcrete pinnedType of
      Just resolved -> normaliseSemantic resolved
      Nothing -> NTUnknown

-- ---------------------------------------------------------------------------
-- Effect worklist (delegated to 'Solver.Effect')
-- ---------------------------------------------------------------------------

solveEffectWorklist ::
  Int ->
  [Constraint] ->
  (Map EffectVarId (Set VariableId), [SolverError])
solveEffectWorklist _ = Effect.solveEffectConstraints

-- ---------------------------------------------------------------------------
-- Total contract: fill missing entries
-- ---------------------------------------------------------------------------

-- | Ensure every 'TypeVarId' allocated by the constraint generator has an
-- entry. Missing entries (vars that the solver could not pin) fall back to
-- 'NTUnknown' (the lattice top) so that downstream phases see "any" rather
-- than "never".
totaliseTypes :: Int -> Map TypeVarId NormalizedType -> Map TypeVarId NormalizedType
totaliseTypes upperLimit given =
  Map.union given $
    Map.fromList [(TypeVarId i, NTUnknown) | i <- [0 .. upperLimit - 1]]

totaliseEffects ::
  Int ->
  Map EffectVarId (Set VariableId) ->
  Map EffectVarId (Set VariableId)
totaliseEffects upperLimit given =
  Map.union given $
    Map.fromList [(EffectVarId i, Set.empty) | i <- [0 .. upperLimit - 1]]
