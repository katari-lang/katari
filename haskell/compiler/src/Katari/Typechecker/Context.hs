-- @world@ / @genericsInScope@ are deliberately shared field names across 'CheckerEnvironment' and the
-- 'SubtypingContext' imported from "Katari.Typechecker.Normalizer" (the project's duplicate-field
-- convention). Both are in scope here, so the record updates in 'withWorld' / 'withGeneric' resolve by
-- the helper's signature — exactly what @-Wambiguous-fields@ (folded into @-Wcompat@) flags. The
-- convention is intentional, so the warning is suppressed for this module.
{-# OPTIONS_GHC -Wno-ambiguous-fields #-}

-- | The checker's runtime context (Phase C, "Katari.Typechecker"): the monad and the read-only
-- environment it threads. Per-kind checking ("Katari.Typechecker.Check", "Katari.Typechecker.Pattern")
-- reads from this; the driver ("Katari.Typechecker") seeds it and walks the value SCCs.
--
-- Three structural ideas organise this module:
--
--   * The /world/ — the attribute of the lexical scope the checker is currently inside. Top-level
--     starts public (bottom); a @private agent@ body raises it to private; a local agent declared in
--     a private world inherits the world. The world and the in-scope generics are kept /flat/ on
--     'CheckerEnvironment'; the 'SubtypingContext' the normalizer needs is assembled from them at the
--     edge ('normalizerEnvironment'), the same way the elaborate context is assembled in 'runElaborator'.
--
--   * /Boundary targets/ — the three lexically-enclosing control-flow boundaries a @return@ / @for@
--     jump / handler jump unwinds to, each a 'BoundaryId' (or 'Nothing' when none is in scope). They
--     mirror "Katari.Lowering"'s @returnTarget@ / @forTarget@ / @handleTarget@ exactly, including the
--     barrier semantics in the @enter*@ helpers (entering an agent clears the @for@ / handler targets;
--     entering a request handler clears the return / @for@ targets — a request handler body is deferred;
--     a @then@ finalizer clears all three). A jump reads its target to tag the escape effect it emits;
--     no target in scope is a misplaced jump.
--
--   * /Global escapes as effects/ — @return@ / @break@ / @next@ do not use bespoke accumulators or
--     purity bookkeeping. Each emits an internal escape effect ('emitExit' / 'emitContinue', tagged with
--     its target 'BoundaryId') into the ordinary effect accumulator; the boundary it names discharges it
--     ('splitExit' / 'splitContinue'). A branch that escapes therefore has a non-pure effect with no
--     special handling, and an escape's value type rides the effect (covariantly) to its boundary.
module Katari.Typechecker.Context where

import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (MonadWriter (..), asks, gets, local, modify)
import Data.Map (Map)
import Data.Map qualified as Map
import GHC.List (List)
import Katari.Data.Environment
  ( GenericParameterInformation,
    Scheme,
    ValueEnvironment,
  )
import Katari.Data.Id (GenericId (..), LocalVariableId, inferenceModuleName)
import Katari.Data.NormalizedType
  ( BoundaryId (..),
    NormalizedAttribute,
    NormalizedEffect,
    NormalizedType,
    bottomAttribute,
    bottomEffect,
    continueEffect,
    exitEffect,
  )
import Katari.Data.QualifiedName (QualifiedName)
import Katari.Data.SourceSpan (SourceSpan)
import Katari.Diagnostics (Diagnostics, diagnosticAt)
import Katari.Error (CompilerError (..))
import Katari.Typechecker.Elaborate (Elaborate, runElaborate, scopeGenerics)
import Katari.Typechecker.Environment (TypeEnvironment (..))
import Katari.Typechecker.Normalizer
  ( Normalizer,
    NormalizerEnvironment,
    SubtypingContext (..),
    TypeLattice,
    joinAttribute,
    union,
  )

------------------------------------------------------------------------------------------------
-- The checker monad
------------------------------------------------------------------------------------------------

-- | The checker's read-only environment.
data CheckerEnvironment = CheckerEnvironment
  { -- | The global type-level environment built by the env-build phase. Also carries the
    -- elaborator's signature registry ('elaborateContext') and the nominal environments the normalizer
    -- needs ('normalizerEnvironment' projects them).
    typeEnvironment :: TypeEnvironment,
    -- | Top-level values whose scheme is known; grown SCC by SCC by the driver as components are
    -- checked, so a callee is registered before any caller is walked.
    valueEnvironment :: ValueEnvironment,
    -- | Locals in scope, keyed by 'LocalVariableId'. A local holds a 'Scheme' like a top-level value.
    locals :: Map LocalVariableId Scheme,
    -- | The attribute of the lexical scope the checker is currently inside (top-level public; a
    -- @private agent@ body raises it). Joined into every subtype comparison by the normalizer.
    world :: NormalizedAttribute,
    -- | The generic parameters currently in scope, keyed by id (an agent's / handler's declared
    -- generics, whose bounds @subtype@ consults).
    genericsInScope :: Map GenericId GenericParameterInformation,
    -- | The enclosing agent a @return@ unwinds to ('Nothing' = none in scope / barred).
    returnTarget :: Maybe BoundaryId,
    -- | The enclosing @for@ a @for@ @next@ / @break@ unwinds to.
    forTarget :: Maybe BoundaryId,
    -- | The enclosing request handler a handler @next@ / @break@ unwinds to.
    handlerTarget :: Maybe BoundaryId
  }

-- | Per-walk mutable state: the inference accumulators and the fresh-id counters.
data CheckerState = CheckerState
  { -- | The union of every effect contribution in the innermost effect-collection scope (a
    -- 'withEffectInference' run): non-pure calls, @use@ statements, /and the internal escape effects/
    -- a @return@ / @break@ / @next@ emit. Bottom (pure) outside such a scope.
    effectAccumulator :: NormalizedEffect,
    -- | A monotonically increasing counter for minting fresh inference variables ('freshGenericId').
    metavarCounter :: Int,
    -- | A monotonically increasing counter for minting fresh control-flow boundary ids
    -- ('freshBoundaryId').
    boundaryCounter :: Int
  }
  deriving stock (Eq, Show)

-- | The initial state — the effect accumulator at its bottom, counters at zero.
initialCheckerState :: CheckerState
initialCheckerState = CheckerState {effectAccumulator = bottomEffect, metavarCounter = 0, boundaryCounter = 0}

-- | Mint a fresh inference variable id under the reserved 'inferenceModuleName', advancing the
-- per-walk counter.
freshGenericId :: Checker GenericId
freshGenericId = do
  next <- gets (.metavarCounter)
  modify (\state -> state {metavarCounter = next + 1})
  pure (GenericId inferenceModuleName next)

-- | Mint a fresh control-flow 'BoundaryId' (for an agent / @for@ / request handler being entered),
-- advancing the per-walk counter.
freshBoundaryId :: Checker BoundaryId
freshBoundaryId = do
  next <- gets (.boundaryCounter)
  modify (\state -> state {boundaryCounter = next + 1})
  pure (BoundaryId next)

-- | The checker monad: read-only environment, 'Diagnostics' writer, 'CheckerState' state.
type Checker a = RWS CheckerEnvironment Diagnostics CheckerState a

-- | A fresh checker environment over the given type environment, with nothing else in scope.
initialCheckerEnvironment :: TypeEnvironment -> CheckerEnvironment
initialCheckerEnvironment typeEnvironment =
  CheckerEnvironment
    { typeEnvironment = typeEnvironment,
      valueEnvironment = mempty,
      locals = mempty,
      world = bottomAttribute,
      genericsInScope = mempty,
      returnTarget = Nothing,
      forTarget = Nothing,
      handlerTarget = Nothing
    }

runChecker :: CheckerEnvironment -> Checker a -> (a, Diagnostics)
runChecker environment action =
  let (result, _, diagnostics) = runRWS action environment initialCheckerState in (result, diagnostics)

------------------------------------------------------------------------------------------------
-- Normalizer bridging
------------------------------------------------------------------------------------------------

-- | Assemble the 'SubtypingContext' the normalizer runs against from the checker's flat state — the
-- nominal environments (from 'typeEnvironment'), the in-scope generics and the lexical 'world'. Built at
-- the edge rather than stored pre-built, so the checker keeps a single flat source of truth.
normalizerEnvironment :: Checker NormalizerEnvironment
normalizerEnvironment = do
  typeEnvironment <- asks (.typeEnvironment)
  generics <- asks (.genericsInScope)
  world <- asks (.world)
  pure
    SubtypingContext
      { dataEnvironment = typeEnvironment.dataEnvironment,
        requestEnvironment = typeEnvironment.requestEnvironment,
        genericsInScope = generics,
        world = world
      }

-- | Run a 'Normalizer' sub-action with the current checker environment, anchoring its errors at
-- the given source span (the normalizer is span-free).
runNormalizer :: SourceSpan -> Normalizer a -> Checker a
runNormalizer sourceSpan action = do
  environment <- normalizerEnvironment
  let (result, _, errors) = runRWS action environment ()
  tell (foldMap (diagnosticAt sourceSpan . CompilerErrorType) errors)
  pure result

-- | Run an 'Elaborate' sub-action with the checker's elaborate context, forwarding its already
-- located diagnostics. The two-step pattern is "elaborate to semantic, then normalize through
-- 'runNormalizer'".
runElaborator :: Elaborate a -> Checker a
runElaborator action = do
  context <- asks (.typeEnvironment.elaborateContext)
  generics <- asks (.genericsInScope)
  let scoped = scopeGenerics generics context
      (result, diagnostics) = runElaborate scoped action
  tell diagnostics
  pure result

------------------------------------------------------------------------------------------------
-- World propagation
------------------------------------------------------------------------------------------------

-- | The attribute of the lexical scope the checker is currently inside (the @world@ a @private agent@
-- raises). The closure attribute a nested agent inherits.
currentWorld :: Checker NormalizedAttribute
currentWorld = asks (.world)

-- | Raise the world by @attribute@ for the sub-action: every comparison inside observes the new world.
withWorld :: NormalizedAttribute -> Checker a -> Checker a
withWorld attribute = local raise
  where
    -- @world@ is shared with 'SubtypingContext'; the update resolves by this signature (see the
    -- module-header note on @-Wambiguous-fields@).
    raise :: CheckerEnvironment -> CheckerEnvironment
    raise environment = environment {world = joinAttribute environment.world attribute}

------------------------------------------------------------------------------------------------
-- Environment extension
------------------------------------------------------------------------------------------------

-- | Bring a local variable's scheme into scope for the sub-action.
withLocal :: LocalVariableId -> Scheme -> Checker a -> Checker a
withLocal variableId scheme =
  local (\environment -> environment {locals = Map.insert variableId scheme environment.locals})

-- | Bring a list of @(localId, scheme)@ pairs into scope for the sub-action — the multi-parameter form
-- of 'withLocal'.
withParameters :: List (LocalVariableId, Scheme) -> Checker a -> Checker a
withParameters bindings continuation = foldr applyOne continuation bindings
  where
    applyOne (localId, scheme) = withLocal localId scheme

-- | Permanently register top-level values in the checker environment from this point onward, as the
-- driver iterates the value SCCs.
extendValueEnvironment :: Map QualifiedName Scheme -> CheckerEnvironment -> CheckerEnvironment
extendValueEnvironment additions environment =
  environment {valueEnvironment = environment.valueEnvironment <> additions}

-- | Bring an in-scope generic parameter into scope for the sub-action.
withGeneric :: GenericId -> GenericParameterInformation -> Checker a -> Checker a
withGeneric genericId info = local extend
  where
    -- @genericsInScope@ is shared with 'SubtypingContext'; the update resolves by this signature (see
    -- the module-header note on @-Wambiguous-fields@).
    extend :: CheckerEnvironment -> CheckerEnvironment
    extend environment = environment {genericsInScope = Map.insert genericId info environment.genericsInScope}

------------------------------------------------------------------------------------------------
-- Boundary targets (mirroring 'Katari.Lowering')
------------------------------------------------------------------------------------------------

-- | Enter an agent / closure body with boundary @id@: a @return@ now unwinds to it. The @for@ / handler
-- targets reset — control cannot @break@ / @next@ across an agent boundary.
enterAgentBody :: BoundaryId -> Checker a -> Checker a
enterAgentBody boundaryId = local set
  where
    set :: CheckerEnvironment -> CheckerEnvironment
    set environment = environment {returnTarget = Just boundaryId, forTarget = Nothing, handlerTarget = Nothing}

-- | Enter a @for@ body with boundary @id@: a @for@ @next@ / @break@ targets it; the return / handler
-- targets are kept (a @return@ inside a @for@ targets the enclosing agent).
enterForBody :: BoundaryId -> Checker a -> Checker a
enterForBody boundaryId = local set
  where
    set :: CheckerEnvironment -> CheckerEnvironment
    set environment = environment {forTarget = Just boundaryId}

-- | Enter a request handler body with boundary @id@: a handler @next@ / @break@ targets it. A handler
-- body runs deferred, so it cannot @return@ to (or @for@-jump out of) the enclosing agent; those targets
-- are cleared (only a nested closure's own boundary catches a @return@).
enterRequestHandler :: BoundaryId -> Checker a -> Checker a
enterRequestHandler boundaryId = local set
  where
    set :: CheckerEnvironment -> CheckerEnvironment
    set environment = environment {handlerTarget = Just boundaryId, returnTarget = Nothing, forTarget = Nothing}

-- | Enter a handler @then@ finalizer body: it is jumpless, so every target is cleared (a @return@ /
-- @next@ / @break@ inside has no boundary and is reported misplaced).
enterHandlerThen :: Checker a -> Checker a
enterHandlerThen = local set
  where
    set :: CheckerEnvironment -> CheckerEnvironment
    set environment = environment {returnTarget = Nothing, forTarget = Nothing, handlerTarget = Nothing}

------------------------------------------------------------------------------------------------
-- Inference scope + escape emission
--
-- An inference scope runs a sub-walk with the effect accumulator reset to its bottom, then reads back
-- what the walk collected and restores the outer value, so a nested scope sees only its own
-- contributions. 'accumulateInto' is the dual emit.
------------------------------------------------------------------------------------------------

-- | Run @action@ with the accumulator the lens selects reset to @zero@, restore the outer value after,
-- and return what the action collected alongside its result.
collecting :: (CheckerState -> a) -> (a -> CheckerState -> CheckerState) -> a -> Checker b -> Checker (a, b)
collecting get put zero action = do
  saved <- gets get
  modify (put zero)
  result <- action
  collected <- gets get
  modify (put saved)
  pure (collected, result)

-- | Union @addition@ into the accumulator the lens selects, through the normalizer (anchored at
-- @sourceSpan@). The dual of 'collecting'.
accumulateInto :: (TypeLattice a) => (CheckerState -> a) -> (a -> CheckerState -> CheckerState) -> SourceSpan -> a -> Checker ()
accumulateInto get put sourceSpan addition = do
  current <- gets get
  joined <- runNormalizer sourceSpan (union current addition)
  modify (put joined)

-- | Run an effect-collection scope (an agent body, a @for@ body, a handler request body, a @use@
-- continuation) returning its inferred effect (which now includes any internal escape effects); the
-- effects performed inside do not leak to the enclosing scope.
withEffectInference :: Checker a -> Checker (NormalizedEffect, a)
withEffectInference = collecting (.effectAccumulator) (\value state -> state {effectAccumulator = value}) bottomEffect

-- | An effect contribution (a non-pure call, a @use@) joins the enclosing scope's inferred effect.
emitEffect :: SourceSpan -> NormalizedEffect -> Checker ()
emitEffect = accumulateInto (.effectAccumulator) (\value state -> state {effectAccumulator = value})

-- | Emit an @EXIT(id, T)@ escape (a @return@ / @break@ / @for@-@break@) into the inferred effect; the
-- boundary @id@ discharges it.
emitExit :: SourceSpan -> BoundaryId -> NormalizedType -> Checker ()
emitExit sourceSpan boundaryId valueType = emitEffect sourceSpan (exitEffect boundaryId valueType)

-- | Emit a @CONTINUE(id, T)@ escape (a @next@ / @for@-@next@) into the inferred effect.
emitContinue :: SourceSpan -> BoundaryId -> NormalizedType -> Checker ()
emitContinue sourceSpan boundaryId valueType = emitEffect sourceSpan (continueEffect boundaryId valueType)
