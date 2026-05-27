-- | Typechecker phase 3: Solve constraints for type variables (bound-pair model).
--
-- Input  : 'ConstraintGenResult' (the AST + constraints from phase 2).
-- Output : 'SolverResult' — substitutions for every type / request variable
--          allocated in phase 2, plus a list of solver errors encountered
--          during recovery.
--
-- Algorithm (bound-pair model):
--
-- Each type variable α carries a single normalized lower / upper pair
-- in 'VarBounds'. New constraints update the bounds incrementally:
--
--   c ⊑ α  (concrete c)  →  α.lower := unionNT (α.lower) (normalise c)
--   α ⊑ c  (concrete c)  →  α.upper := intersectNT (α.upper) (normalise c)
--   α ⊑ β  (var-var)     →  edge added to var graph
--   α ⊑ shape (composite with var) → branching (shape narrowing)
--   α ⊑ (B|C) where (B|C) contains var → branching (rare; union with internal var)
--   structural same-shape composite → 'Solver/Decompose.hs' splits into inner constraints
--   structural diff-shape composite → error
--
-- The top-level loop is two-stage:
--
--   1. **Pre-branch loop**: decompose → classify → eager-pin, repeated
--      until no further bounds/edge updates fire. Eager pinning (= when a
--      var's lower NT equals its upper NT, or when lower ⊄ upper) is the
--      key tool for taming the branching tree: pinning a var via
--      substitution removes it from the worklist and unblocks downstream
--      classifications. A round of var-graph propagation runs at the end
--      of the pre-branch loop so transitively-inherited bounds feed both
--      eager pinning and shape-narrowing 'translate-on-pin'.
--
--   2. **Branch step**: pick one remaining branchable constraint and try
--      each alternative in turn. Failures fall through to the next alt
--      (Option-1 main-branch policy: if all alts fail, surface the FIRST
--      alt's error rather than a synthetic "all branches failed" string).
--
-- After the worklist settles, the var-graph transitive closure once more
-- propagates bounds and the final substitution pins each var to its lower
-- bound (= the most precise type subsuming every concrete flow);
-- inconsistent vars fall back to 'NormalizedTypeUnknown' with a
-- 'SolverErrorBoundsConflict' for diagnostics.
module Katari.Typechecker.Solver
  ( -- * Result (re-exported from 'Solver.Internal')
    SolverResult (..),
    SolverError (..),

    -- * Diagnostics
    toDiagnostic,

    -- * Entry
    solve,
  )
where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Katari.Diagnostic (Diagnostic, diagnosticError)
import Katari.Id ()
import Katari.SemanticType
  ( RequestVariableId (..),
    Resolved,
    SemanticType (..),
    TypeVariableId (..),
    Unresolved,
    singletonRequestVariable,
    substituteVariable,
  )
import Katari.SemanticType.Render qualified as STR
import Katari.SourceSpan (HasSourceSpan (..), Position (..), SourceSpan (..))
import Katari.Typechecker.ConstraintGenerator
  ( Constraint (..),
    ConstraintGenResult (..),
    ConstraintReason (..),
    ReasonKind (..),
    VariableSupply (..),
  )
import Katari.Typechecker.NormalizedType
  ( NormalizedType (..),
    denormalise,
    normaliseSemantic,
  )
import Katari.Typechecker.Solver.Bounds qualified as Bounds
import Katari.Typechecker.Solver.Branch qualified as Branch
import Katari.Typechecker.Solver.Decompose qualified as Decompose
import Katari.Typechecker.Solver.Internal
import Katari.Typechecker.Solver.Request qualified as Request
import Katari.Typechecker.Solver.Substitution qualified as Substitution

-- ===========================================================================
-- Top-level entry
-- ===========================================================================

solve :: ConstraintGenResult -> (SolverResult, [SolverError])
solve cgResult =
  let allConstraints = cgResult.constraints
      typeConstraints = Set.filter isTypeConstraint allConstraints
      requestConstraints = Set.filter isRequestConstraint allConstraints
      (typeSubstitution_, typeErrors) =
        solveTypeWorklist
          cgResult.variableSupply.typeVarSupply
          cgResult.variableSupply.requestVarSupply
          typeConstraints
      (requestSubstitution_, requestErrors) =
        Request.solveRequestConstraints requestConstraints
      -- Resolve any lingering RequestVariableIds inside the type
      -- substitution: narrowed function shapes carry fresh request vars,
      -- and 'semanticToConcrete' would otherwise reject them in the final
      -- NT conversion below.
      typeSubAfterRequest =
        Map.map (Substitution.applyRequestSubstToType requestSubstitution_) typeSubstitution_
      result =
        SolverResult
          { typeSubstitution =
              totalise
                cgResult.variableSupply.typeVarSupply
                TypeVariableId
                NormalizedTypeUnknown
                (Map.map normaliseOrUnknown typeSubAfterRequest),
            requestSubstitution =
              totalise
                cgResult.variableSupply.requestVarSupply
                RequestVariableId
                Set.empty
                requestSubstitution_
          }
   in (result, typeErrors <> requestErrors)

-- ---------------------------------------------------------------------------
-- Solver state
-- ---------------------------------------------------------------------------

-- | State threaded through the worklist iterations and branches.
data SolveState = SolveState
  { -- | Pins from eager-pin and shape-narrowing branches.
    stSubst :: !Substitution,
    -- | Per-var lower / upper aggregation (bound-pair model).
    stBounds :: !BoundsMap,
    -- | Var-on-var subtype edges; transitive closure runs after the
    -- pre-branch loop converges to feed eager pinning and shape narrowing.
    stGraph :: !VarGraph,
    -- | Accumulated non-fatal errors (= bounds conflicts detected during
    -- eager pinning).
    stErrors :: ![SolverError],
    -- | Fresh-var counter (= for shape narrowing).
    stNextTypeVarId :: !Int,
    -- | Fresh-request-var counter (= for narrowed function shapes).
    stNextRequestVarId :: !Int
  }

initialSolveState :: Int -> Int -> SolveState
initialSolveState tvSupply rvSupply =
  SolveState
    { stSubst = Map.empty,
      stBounds = Map.empty,
      stGraph = Map.empty,
      stErrors = [],
      stNextTypeVarId = tvSupply,
      stNextRequestVarId = rvSupply
    }

-- ---------------------------------------------------------------------------
-- Type worklist entry
-- ---------------------------------------------------------------------------

-- | Top-level type-constraint solver. Returns the final substitution and
-- any errors. The substitution composes shape-narrowing pins with
-- bound-aggregation pins; the caller then runs request resolution and
-- totalisation.
solveTypeWorklist ::
  Int ->
  Int ->
  Set Constraint ->
  (Substitution, [SolverError])
solveTypeWorklist tvSupply rvSupply initialConstraints =
  case solveLoop (initialSolveState tvSupply rvSupply) initialConstraints of
    Left fatal -> (Map.empty, [fatal])
    Right finalState ->
      let propagated = Bounds.propagateBoundsViaGraph finalState.stGraph finalState.stBounds
          boundsErrors = collectBoundsErrors propagated
          boundsSubst = boundsMapToSubstitution propagated
          -- Shape-narrow pins override bound aggregation when both exist
          -- (= once a var is committed to a shape via branching, its
          -- bound entries are stale and the shape value wins).
          combined = Map.union finalState.stSubst boundsSubst
          resolved = resolveDeepSubst combined
       in (resolved, finalState.stErrors <> boundsErrors)

-- ---------------------------------------------------------------------------
-- Pre-branch loop + branching
-- ---------------------------------------------------------------------------

-- | Drive the worklist to a converged state (= no more eager pins, no
-- more branching opportunities). Branching at the end fans out into
-- alternatives via 'tryBranches'.
solveLoop :: SolveState -> Set Constraint -> Either SolverError SolveState
solveLoop state worklist
  | Set.null worklist = Right state
  | otherwise = do
      let substituted = Set.map (Substitution.applySubstConstraint state.stSubst) worklist
      decomposed <- Decompose.decomposeConstraintsAll substituted
      let (classified, leftover) = classifyAll decomposed state
      case Bounds.findEagerPins classified.stBounds of
        pins@(_ : _) -> solveLoop (applyEagerPins pins classified) decomposed
        [] ->
          -- No direct eager pins yet. Var-graph propagation can carry
          -- concrete bounds across var-var edges; the newly merged
          -- bounds may unlock further eager pins, and also feed into
          -- 'runBranchAlt's translate-on-pin so shape narrowing checks
          -- transitively-inherited bounds against the pinned shape.
          let propagatedBounds = Bounds.propagateBoundsViaGraph classified.stGraph classified.stBounds
              afterPropagation = classified {stBounds = propagatedBounds}
           in case Bounds.findEagerPins propagatedBounds of
                pins@(_ : _) -> solveLoop (applyEagerPins pins afterPropagation) decomposed
                [] -> case findBranchable
                  afterPropagation.stNextTypeVarId
                  afterPropagation.stNextRequestVarId
                  leftover of
                  Just (chosen, alts) -> tryBranches afterPropagation chosen leftover alts
                  Nothing -> Right afterPropagation

-- | Apply a batch of eager-pin decisions: each pin is inserted into
-- 'stSubst', the var's bounds entry dropped, and inconsistent pins
-- (= 'epInconsistent') push a 'SolverErrorBoundsConflict' for diagnostics.
applyEagerPins :: [Bounds.EagerPin] -> SolveState -> SolveState
applyEagerPins = flip (foldr applyOne)
  where
    applyOne pin acc =
      let value = ntToUnresolved pin.epValue
          acc' =
            acc
              { stSubst = Map.insert pin.epTypeVarId value acc.stSubst,
                stBounds = Map.delete pin.epTypeVarId acc.stBounds
              }
       in if pin.epInconsistent
            then acc' {stErrors = mkBoundsConflictError pin : acc'.stErrors}
            else acc'

-- | Try each branch alternative in order; on the first success, return
-- the resulting state. Per Option-1 main-branch policy, if all alts fail
-- we surface the FIRST alt's error rather than a synthetic message.
-- 'branchConstraint' guarantees the alts list is non-empty.
tryBranches ::
  SolveState ->
  Constraint ->
  Set Constraint ->
  [Branch.BranchAlt] ->
  Either SolverError SolveState
tryBranches state chosen worklist (mainAlt : restAlts) =
  case runBranchAlt state chosen worklist mainAlt of
    Right done -> Right done
    Left mainErr -> case firstSuccess (map (runBranchAlt state chosen worklist) restAlts) of
      Just done -> Right done
      Nothing -> Left mainErr
tryBranches _ _ _ [] =
  -- Unreachable: 'Branch.branchConstraint' always returns ≥ 1 alt.
  error "Solver.tryBranches: empty alt list"

firstSuccess :: [Either e a] -> Maybe a
firstSuccess = foldr (\r acc -> either (const acc) Just r) Nothing

runBranchAlt ::
  SolveState ->
  Constraint ->
  Set Constraint ->
  Branch.BranchAlt ->
  Either SolverError SolveState
runBranchAlt state chosen worklist alt =
  let combinedSubst = Map.union alt.branchSubst state.stSubst
      -- For each var pinned by this alt's substitution, translate its
      -- existing bounds into fresh subtype constraints against the
      -- pinned value (= so any incompatibility is detected on re-loop).
      -- The bounds themselves are dropped — subst supersedes them.
      pinnedBoundConstraints =
        concatMap
          (\(α, value) -> boundsToConstraints α value state.stBounds)
          (Map.toList alt.branchSubst)
      bounds' = foldr Map.delete state.stBounds (Map.keys alt.branchSubst)
      newWorklist =
        Set.unions
          [ alt.branchNewConstraints,
            Set.delete chosen worklist,
            Set.fromList pinnedBoundConstraints
          ]
      state' =
        state
          { stSubst = combinedSubst,
            stBounds = bounds',
            stNextTypeVarId = alt.branchNextTypeVariableId,
            stNextRequestVarId = alt.branchNextRequestVariableId
          }
   in solveLoop state' newWorklist

-- | Find the first constraint in the worklist that can be branched
-- (= var vs composite shape or var ⊑ var-bearing union). 'Set.toAscList'
-- gives a deterministic iteration order across runs.
findBranchable ::
  Int ->
  Int ->
  Set Constraint ->
  Maybe (Constraint, [Branch.BranchAlt])
findBranchable nextTV nextRV constraints = go (Set.toAscList constraints)
  where
    go [] = Nothing
    go (current : rest) =
      case Branch.branchConstraint nextTV nextRV current of
        Just alts -> Just (current, alts)
        Nothing -> go rest

-- ---------------------------------------------------------------------------
-- Per-constraint classification
-- ---------------------------------------------------------------------------

-- | Process every constraint in the input set, dispatching each into
-- bound update / edge add / settled / leftover. Leftover constraints
-- need branching at the next stage.
classifyAll :: Set Constraint -> SolveState -> (SolveState, Set Constraint)
classifyAll constraints = foldr step (\s -> (s, Set.empty)) (Set.toList constraints)
  where
    step c k state =
      let (state', leftoverFlag) = classifyOne c state
          (final, leftover) = k state'
       in (final, if leftoverFlag then Set.insert c leftover else leftover)

-- | Classify a single constraint. Returns 'True' iff it must wait for
-- branching (= 'leftover'); 'False' if handled directly (= bound update,
-- edge add, or settled).
classifyOne :: Constraint -> SolveState -> (SolveState, Bool)
classifyOne RequestConstraint {} state = (state, False)
-- Request constraints are filtered out upstream in 'solve'.
classifyOne (TypeConstraint leftType rightType reason) state =
  case (leftType, rightType) of
    -- Var ⊑ Var: record edge for post-loop graph propagation.
    (SemanticTypeVariable a, SemanticTypeVariable b) ->
      (state {stGraph = Bounds.addVarEdge a b state.stGraph}, False)
    -- Concrete (no type vars) ⊑ Var α: add to α's lower.
    (concrete, SemanticTypeVariable a)
      | Set.null (typeVarsIn concrete) ->
          tryBoundUpdate (addLower a) concrete reason state
    -- Var α ⊑ Concrete (no type vars): add to α's upper.
    (SemanticTypeVariable a, concrete)
      | Set.null (typeVarsIn concrete) ->
          tryBoundUpdate (addUpper a) concrete reason state
    -- Otherwise: structural decomposition (done by 'Decompose') or shape
    -- narrowing (via 'findBranchable'). Leftover.
    _ -> (state, True)
  where
    tryBoundUpdate update concrete reason' s =
      case normaliseRequestStripped concrete of
        Just nt -> (update nt reason' s, False)
        Nothing -> (s, True)

    addLower a nt reason' s =
      let updated = Bounds.addLowerConcrete nt reason' (Bounds.lookupBounds a s.stBounds)
       in s {stBounds = Map.insert a updated s.stBounds}

    addUpper a nt reason' s =
      let updated = Bounds.addUpperConcrete nt reason' (Bounds.lookupBounds a s.stBounds)
       in s {stBounds = Map.insert a updated s.stBounds}

-- ---------------------------------------------------------------------------
-- Bound translation for branching
-- ---------------------------------------------------------------------------

-- | Convert a var's existing 'VarBounds' into fresh subtype constraints
-- against the pinned value. Called when branching commits the var to a
-- specific shape and the old bound info must be re-validated against
-- the commitment.
boundsToConstraints ::
  TypeVariableId ->
  SemanticType Unresolved ->
  BoundsMap ->
  [Constraint]
boundsToConstraints α value bm = case Map.lookup α bm of
  Nothing -> []
  Just vb ->
    let lowerCs
          | Bounds.isNeverNT vb.vbLower = []
          | otherwise =
              [ TypeConstraint
                  (denormaliseToUnresolved vb.vbLower)
                  value
                  (headReason vb.vbLowerReasons)
              ]
        upperCs
          | Bounds.isUnknownNT vb.vbUpper = []
          | otherwise =
              [ TypeConstraint
                  value
                  (denormaliseToUnresolved vb.vbUpper)
                  (headReason vb.vbUpperReasons)
              ]
     in lowerCs <> upperCs

-- ---------------------------------------------------------------------------
-- Post-worklist: bounds → substitution + bounds-conflict diagnostics
-- ---------------------------------------------------------------------------

-- | Pick the final 'NormalizedType' for each variable from its bounds,
-- then re-encode as 'SemanticType' 'Unresolved' for the substitution
-- composition with the shape-narrow pins.
boundsMapToSubstitution :: BoundsMap -> Substitution
boundsMapToSubstitution = Map.map ntToUnresolved . Bounds.finalizeBoundsToSubstitution

-- | Emit a 'SolverErrorBoundsConflict' for every var whose lower is
-- not a subtype of its upper. The reasons are picked from the most
-- recent contribution on each side; richer aggregation is a future UX
-- improvement.
collectBoundsErrors :: BoundsMap -> [SolverError]
collectBoundsErrors =
  mapMaybe diag . Map.toList
  where
    diag (a, vb)
      | Bounds.isVarBoundsConsistent vb = Nothing
      | otherwise = Just (mkBoundsConflictErrorWith a vb defaultReason)

-- ---------------------------------------------------------------------------
-- Helpers shared across the solver
-- ---------------------------------------------------------------------------

-- | Construct a 'SolverErrorBoundsConflict' from an 'EagerPin'.
mkBoundsConflictError :: Bounds.EagerPin -> SolverError
mkBoundsConflictError pin =
  mkBoundsConflictErrorWith
    pin.epTypeVarId
    pin.epBounds
    (headReason pin.epBounds.vbLowerReasons)

-- | Lower-level construction of 'SolverErrorBoundsConflict' from the
-- target var, its bounds, and a fallback reason for empty reason lists.
mkBoundsConflictErrorWith ::
  TypeVariableId ->
  VarBounds ->
  ConstraintReason ->
  SolverError
mkBoundsConflictErrorWith a vb fallback =
  SolverErrorBoundsConflict
    a
    (firstReasonOr fallback vb.vbLowerReasons)
    (denormalise vb.vbLower)
    (firstReasonOr fallback vb.vbUpperReasons)
    (denormalise vb.vbUpper)

firstReasonOr :: ConstraintReason -> [ConstraintReason] -> ConstraintReason
firstReasonOr fallback = \case
  (r : _) -> r
  [] -> fallback

headReason :: [ConstraintReason] -> ConstraintReason
headReason = firstReasonOr defaultReason

defaultReason :: ConstraintReason
defaultReason = ConstraintReason {kind = ReasonKindSolverInternal, sourceSpan = dummySpan}

dummySpan :: SourceSpan
dummySpan =
  SrcSpan
    { filePath = "",
      start = Position {line = 0, column = 0},
      end = Position {line = 0, column = 0}
    }

-- | Normalise a 'SemanticType' 'Unresolved' that contains no type
-- variables but may carry 'RequestVariableId's. Request vars are
-- stripped to empty sets — sound for type-level bound aggregation,
-- which doesn't care about effects. Returns 'Nothing' if the type
-- still contains type variables (defensive; the caller pre-checks via
-- 'containsNoTypeVars').
normaliseRequestStripped :: SemanticType Unresolved -> Maybe NormalizedType
normaliseRequestStripped =
  fmap normaliseSemantic
    . semanticToConcrete
    . Substitution.applyRequestSubstToType Map.empty

-- | Normalise a (possibly variable-bearing) 'SemanticType' 'Unresolved',
-- falling back to 'NormalizedTypeUnknown' if it still mentions a type
-- variable. Used at the final substitution conversion.
normaliseOrUnknown :: SemanticType Unresolved -> NormalizedType
normaliseOrUnknown = maybe NormalizedTypeUnknown normaliseSemantic . semanticToConcrete

-- | 'NormalizedType' → 'SemanticType' 'Unresolved' via 'denormalise'.
-- Unknown stays as 'SemanticTypeUnknown'; everything else round-trips
-- through the Resolved phase and lifts to Unresolved structurally.
ntToUnresolved :: NormalizedType -> SemanticType Unresolved
ntToUnresolved = \case
  NormalizedTypeUnknown -> SemanticTypeUnknown
  nt -> denormaliseToUnresolved nt

denormaliseToUnresolved :: NormalizedType -> SemanticType Unresolved
denormaliseToUnresolved = liftResolved . denormalise

liftResolved :: SemanticType Resolved -> SemanticType Unresolved
liftResolved =
  runIdentity
    . substituteVariable
      (Identity . SemanticTypeVariable)
      (Identity . singletonRequestVariable)

-- | Compose a substitution with itself until a fixpoint, so that an
-- indirect entry like @α := F(t_p)@ collapses to @α := F(Int)@ once
-- @t_p := Int@ is also pinned. Without this step the public output
-- would carry transitive 'SemanticTypeVariable' references that
-- 'semanticToConcrete' rejects, forcing the downstream to fall back to
-- 'NormalizedTypeUnknown'.
resolveDeepSubst :: Substitution -> Substitution
resolveDeepSubst sub =
  let next = Substitution.applySubstSubst sub sub
   in if next == sub then sub else resolveDeepSubst next

-- | Fill missing entries in a totalisable map with a default value.
-- Used to satisfy the totality contract: downstream phases expect every
-- ID allocated by the constraint generator to have an entry, even when
-- the solver failed to pin a value.
totalise :: (Ord k) => Int -> (Int -> k) -> v -> Map k v -> Map k v
totalise upperLimit toKey def given =
  Map.union given (Map.fromList [(toKey i, def) | i <- [0 .. upperLimit - 1]])

-- ===========================================================================
-- Diagnostics
-- ===========================================================================

-- | Convert a 'SolverError' to a unified 'Diagnostic'. Codes K0220-K0249
-- are reserved for the solver.
--
-- Type-renderer name maps default to empty when callers don't have
-- them — primitive types render fine without; data names degrade to a
-- placeholder. Production call sites (= 'Katari.Compile') populate
-- both maps so diagnostics print e.g. /"expected `User`, found `Int`"/.
toDiagnostic :: SolverError -> Diagnostic
toDiagnostic = \case
  -- (left ⊑ right): the user's "expected" type is the supertype on the
  -- RIGHT (= what the context required); the "found" type is the
  -- subtype on the LEFT (= what was actually produced).
  SolverErrorContradiction reason actual expected ->
    diagnosticError
      "K0220"
      ( "type contradiction at "
          <> renderReason reason
          <> ": expected `"
          <> renderTy expected
          <> "`, found `"
          <> renderTy actual
          <> "`"
      )
      (sourceSpanOf reason)
  SolverErrorBoundsConflict (TypeVariableId tv) lowerReason lower upperReason upper ->
    diagnosticError
      "K0221"
      ( "type-variable bounds conflict for α"
          <> T.pack (show tv)
          <> ": lower bound `"
          <> renderTy lower
          <> "` ("
          <> renderReason lowerReason
          <> ") incompatible with upper bound `"
          <> renderTy upper
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
    renderTy = STR.renderSemanticType
    renderReason r = T.pack (show r.kind)
