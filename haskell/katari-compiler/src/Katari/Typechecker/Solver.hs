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
    isTypeConstraint,
    isEffectConstraint,

    -- * Diagnostics
    toDiagnostic,

    -- * Entry
    solve,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.AST (HasSourceSpan (..), Position (..), SourceSpan (..))
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintGenResult (..),
    ConstraintReason (..),
    ReasonKind (..),
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
      typeConstraints = Set.filter isTypeConstraint allConstraints
      effectConstraints = Set.filter isEffectConstraint allConstraints
      (typeSubstitution_, typeErrors) =
        solveTypeWorklist cgResult.nextTypeVarId cgResult.nextEffectVarId typeConstraints
      (effectSubstitution_, effectErrors) =
        solveEffectWorklist cgResult.nextEffectVarId effectConstraints
      -- Apply the effect substitution to the type sub's values so that
      -- narrowed function shapes (which carry fresh effect vars) become
      -- effect-concrete before 'substToNormalizedSafe' inspects them.
      typeSubAfterEffect =
        Map.map (Substitution.applyEffectSubstToType effectSubstitution_) typeSubstitution_
      normalizedTypeSubstitution = substToNormalizedSafe typeSubAfterEffect
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
  Set Constraint ->
  (Substitution, [SolverError])
solveTypeWorklist startNextTypeVarId startNextEffectVarId initialConstraints =
  case go startNextTypeVarId startNextEffectVarId initialConstraints Map.empty of
    Right substitution -> (substitution, [])
    Left err -> (Map.empty, [err])
  where
    go ::
      Int ->
      Int ->
      Set Constraint ->
      Substitution ->
      Either SolverError Substitution
    go nextTypeVarId nextEffectVarId constraints accumulatedSubstitution = do
      let substituted =
            Set.map (Substitution.applySubstConstraint accumulatedSubstitution) constraints
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
                  merged = Map.union collected accumulatedSubstitution
                  finalSubstitution = resolveDeepSubst merged
              case checkContradictions propagated of
                [] -> pure finalSubstitution
                (firstError : _) -> Left firstError

    -- \| Try each branch alternative in order; on the first 'Right' return
    -- it, otherwise fall through to the next. Each branch carries its own
    -- partial substitution which is unioned into the inherited one before
    -- recursing into 'go'.
    --
    -- The single-branch case is special-cased so the actual 'go' error
    -- bubbles up unchanged (more informative for diagnostics) instead of
    -- being collapsed into the generic "all branches failed" message that
    -- the empty case emits when every alternative was tried and rejected.
    tryBranches ::
      Int ->
      Int ->
      Substitution ->
      [(Substitution, Set Constraint, Int, Int)] ->
      Either SolverError Substitution
    tryBranches _ _ _ [] =
      Left
        ( SolverErrorStructuralMismatch
            (synthesisedReason initialConstraints)
            "all branches failed"
        )
    tryBranches _ _ accumulatedSubstitution [(branchSubstitution, branchConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter)] =
      runBranch accumulatedSubstitution branchSubstitution branchConstraints nextTypeVarIdAfter nextEffectVarIdAfter
    tryBranches nextTypeVarId nextEffectVarId accumulatedSubstitution ((branchSubstitution, branchConstraints, nextTypeVarIdAfter, nextEffectVarIdAfter) : remainingBranches) =
      case runBranch accumulatedSubstitution branchSubstitution branchConstraints nextTypeVarIdAfter nextEffectVarIdAfter of
        Right successSubstitution -> Right successSubstitution
        Left _ ->
          tryBranches nextTypeVarId nextEffectVarId accumulatedSubstitution remainingBranches

    runBranch ::
      Substitution ->
      Substitution ->
      Set Constraint ->
      Int ->
      Int ->
      Either SolverError Substitution
    runBranch accumulatedSubstitution branchSubstitution branchConstraints nextTypeVarIdAfter nextEffectVarIdAfter =
      let combinedSubstitution = Map.union branchSubstitution accumulatedSubstitution
       in go nextTypeVarIdAfter nextEffectVarIdAfter branchConstraints combinedSubstitution

-- | Compose a substitution with itself until a fixpoint, so that an
-- indirect entry like @α := F(t_p)@ collapses to @α := F(Int)@ once
-- @t_p := Int@ has also been pinned. Without this step, the public output
-- of the solver would carry transitive 'SemanticTypeVariable' references
-- that 'semanticToConcrete' rejects, forcing the downstream to fall back
-- to 'NTUnknown'.
--
-- Termination: each iteration is monotone (no entry gains new 'TypeVarId'
-- references) and the substitution is finite. Self-referential cycles
-- (@α := SemanticTypeVariable α@) reach the fixpoint immediately as
-- 'applySubstSubst' folds them into themselves; downstream
-- 'semanticToConcrete' surfaces them as 'NTUnknown', the correct result
-- for an unresolvable cyclic var.
resolveDeepSubst :: Substitution -> Substitution
resolveDeepSubst substitution =
  let next = Substitution.applySubstSubst substitution substitution
   in if next == substitution then substitution else resolveDeepSubst next

-- | Detect concrete-vs-concrete contradictions in remaining constraints
-- after propagation.
checkContradictions :: Set Constraint -> [SolverError]
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
synthesisedReason :: Set Constraint -> ConstraintReason
synthesisedReason constraints =
  ConstraintReason ReasonSolverInternal originSpan
  where
    originSpan =
      case [reason.sourceSpan | TypeConstraint _ _ reason <- Set.toAscList constraints] of
        (firstSpan : _) -> firstSpan
        [] -> dummySpan
    dummySpan =
      SrcSpan
        { filePath = "",
          start = Position {line = 0, column = 0},
          end = Position {line = 0, column = 0}
        }

-- | Convert each pinned 'SemanticType' 'Unresolved' to the public
-- 'NormalizedType' form. Variables that are still unresolved post-solve
-- (defensive case — should not normally happen) fall back to 'NTUnknown',
-- the lattice top, so that downstream phases treat them as "any" rather
-- than "never".
substToNormalizedSafe :: Substitution -> Map TypeVarId NormalizedType
substToNormalizedSafe = Map.map convert
  where
    convert pinnedType = maybe NTUnknown normaliseSemantic (semanticToConcrete pinnedType)

-- ---------------------------------------------------------------------------
-- Effect worklist (delegated to 'Solver.Effect')
-- ---------------------------------------------------------------------------

solveEffectWorklist ::
  Int ->
  Set Constraint ->
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

-- ===========================================================================
-- Diagnostics
-- ===========================================================================

-- | Convert a 'SolverError' to a unified 'Diagnostic'. Codes K0220-K0249
-- are reserved for the solver. Type rendering is shallow (uses 'Show')
-- because solver diagnostics carry both sides for tools to render
-- structurally.
toDiagnostic :: SolverError -> Diagnostic
toDiagnostic = \case
  SolverErrorContradiction reason expected found ->
    diagnosticError
      "K0220"
      ( "type contradiction at "
          <> renderReason reason
          <> ": expected `"
          <> tShow expected
          <> "`, found `"
          <> tShow found
          <> "`"
      )
      (sourceSpanOf reason)
  SolverErrorBoundsConflict (TypeVarId tv) lowerReason lower upperReason upper ->
    diagnosticError
      "K0221"
      ( "type-variable bounds conflict for α"
          <> tShow tv
          <> ": lower bound `"
          <> tShow lower
          <> "` ("
          <> renderReason lowerReason
          <> ") incompatible with upper bound `"
          <> tShow upper
          <> "` ("
          <> renderReason upperReason
          <> ")"
      )
      (sourceSpanOf lowerReason)
  SolverErrorStructuralMismatch reason msg ->
    diagnosticError
      "K0222"
      ("structural type mismatch: " <> msg)
      (sourceSpanOf reason)
  where
    tShow :: (Show a) => a -> Text
    tShow = T.pack . show

    renderReason :: ConstraintReason -> Text
    renderReason r = tShow r.kind
