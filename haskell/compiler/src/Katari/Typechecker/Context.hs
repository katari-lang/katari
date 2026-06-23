-- | The checker's runtime context (Phase C, "Katari.Typechecker"): the monad and the read-only
-- environment it threads. Per-kind checking ("Katari.Typechecker.Check", "Katari.Typechecker.Pattern")
-- reads from this; the driver ("Katari.Typechecker") seeds it and walks the value SCCs.
--
-- Three structural ideas organise this module:
--
--   * The /world/ — the attribute of the lexical scope the checker is currently inside. Top-level
--     starts public (bottom); a @private agent@ body raises it to private; a local agent declared in
--     a private world inherits the world (the value's outer attribute joins it). Every subtype
--     comparison goes through the normalizer which joins the world into both sides, so attribute
--     propagation is contextual, not pushed down. The world and the in-scope generics are kept /flat/
--     on 'CheckerEnvironment'; the 'SubtypingContext' the normalizer needs is assembled from them at
--     the edge ('normalizerEnvironment'), the same way the elaborate context is assembled in
--     'runElaborator' — neither is stored pre-built.
--
--   * /Jump frames/ — a stack of the control-flow boundaries the walk has descended through, innermost
--     first. The frames are pure markers (they carry no type); a jump's validity is decided by /scanning/
--     the stack for its target, blocked by a /barrier/ frame ('hasTarget'). A @return@ finds the
--     enclosing agent / closure ('ReturnFrame'); a @for@ @next@ / @break@ the enclosing @for@
--     ('ForFrame'); a handler @next@ / @break@ the enclosing request handler ('RequestHandlerFrame').
--     A 'RequestHandlerFrame' is a barrier to @return@ (a @return@ may not escape a request handler — only
--     a nested closure's own 'ReturnFrame' catches it), and a 'HandlerThenFrame' is a barrier to every
--     jump (a handler @then@ finalizer is jumpless). Jumplessness is thus expressed /in the stack/ (a
--     barrier frame), not by clearing it.
--
--   * /Inference scopes/ — the value channels a construct collects while its result type is inferred:
--     the @return@ values of an agent ('returnAccumulator'), the @next@ / body-tail values of a @for@ or
--     a request handler ('nextAccumulator'), and the @break@ values of a @for@ or a handler
--     ('breakAccumulator'). A jump emits into the matching channel; the construct reads it back at its
--     edge ('with*Inference' snapshots / resets / restores so a nested scope sees only its own
--     contributions). The dual control-flow bookkeeping ('escapingJumps') drives branch purity.
module Katari.Typechecker.Context where

import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (MonadWriter (..), asks, gets, local, modify)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.List (List)
import Katari.Data.Environment
  ( GenericParameterInformation,
    Scheme,
    ValueEnvironment,
  )
import Katari.Data.Id (GenericId (..), LocalVariableId, inferenceModuleName)
import Katari.Data.NormalizedType
  ( NormalizedAttribute,
    NormalizedEffect,
    NormalizedType,
    bottomAttribute,
    bottomEffect,
    bottomType,
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
-- Jump frames
------------------------------------------------------------------------------------------------

-- | The stack of control-flow boundaries in scope at one point of the walk, innermost first. The frames
-- are pure markers; a jump consults the stack through 'hasTarget', which decides validity by the first
-- frame /relevant/ to that jump (its target, or a barrier that blocks it).
newtype JumpContexts = JumpContexts {frames :: List JumpFrame}
  deriving stock (Eq, Show)

-- | One control-flow boundary the walk has descended through. No frame carries a type: a jump value is
-- checked at the construct's /edge/ (an agent's against its return type, a request handler's @next@ /
-- body tail against the request return type), not where the jump is written.
data JumpFrame
  = -- | An agent / closure body: the target of @return@.
    ReturnFrame
  | -- | A @for@ body: the target of @for@ @next@ / @break@.
    ForFrame
  | -- | A request handler body: the target of a handler @next@ / @break@, and a /barrier/ to @return@ (a
    -- @return@ may not escape a request handler — only a nested closure's own 'ReturnFrame' catches it).
    RequestHandlerFrame
  | -- | A handler @then@ finalizer body: a /barrier/ to every jump (a handler @then@ is jumpless).
    HandlerThenFrame
  deriving stock (Eq, Show)

emptyJumpContexts :: JumpContexts
emptyJumpContexts = JumpContexts {frames = []}

-- | A frame's relevance to a particular jump, while scanning for the jump's target.
data FrameRole
  = -- | This frame captures the jump: it is in scope.
    Target
  | -- | This frame blocks the jump: it is out of scope (the jump may not escape past this boundary).
    Barrier
  | -- | This frame is irrelevant to the jump: keep scanning past it.
    Transparent
  deriving stock (Eq, Show)

-- | Scan the frame stack innermost-first: the jump is in scope iff the first frame that is not
-- 'Transparent' to it is its 'Target' (a 'Barrier' encountered first blocks it). The single home of the
-- "find my target, but not past a barrier" rule every jump shares.
hasTarget :: (JumpFrame -> FrameRole) -> JumpContexts -> Bool
hasTarget role contexts = go contexts.frames
  where
    go = \case
      [] -> False
      frame : rest -> case role frame of
        Target -> True
        Barrier -> False
        Transparent -> go rest

-- | Whether a @return@ has an enclosing agent / closure to target. A request handler or a handler @then@
-- encountered first blocks it (a @return@ may not escape either); a @for@ is transparent (a @return@
-- inside a @for@ targets the enclosing agent).
returnInScope :: JumpContexts -> Bool
returnInScope =
  hasTarget $ \case
    ReturnFrame -> Target
    RequestHandlerFrame -> Barrier
    HandlerThenFrame -> Barrier
    ForFrame -> Transparent

-- | Whether a handler @next@ / @break@ has an enclosing request handler to target. A handler @then@ or an
-- agent / closure boundary encountered first blocks it; a @for@ is transparent.
handlerJumpInScope :: JumpContexts -> Bool
handlerJumpInScope =
  hasTarget $ \case
    RequestHandlerFrame -> Target
    HandlerThenFrame -> Barrier
    ReturnFrame -> Barrier
    ForFrame -> Transparent

-- | Whether a @for@ @next@ / @break@ has an enclosing @for@ to target. Any agent / handler boundary
-- encountered first blocks it (a @for@ jump may not escape a deferred body).
forJumpInScope :: JumpContexts -> Bool
forJumpInScope =
  hasTarget $ \case
    ForFrame -> Target
    _ -> Barrier

------------------------------------------------------------------------------------------------
-- The checker monad
------------------------------------------------------------------------------------------------

-- | The checker's read-only environment.
data CheckerEnvironment = CheckerEnvironment
  { -- | The global type-level environment built by the env-build phase. Also carries the
    -- elaborator's signature registry ('elaborateContext'), so the checker can elaborate type /
    -- effect / attribute annotations encountered inside agent bodies, and the nominal environments the
    -- normalizer needs ('normalizerEnvironment' projects them).
    typeEnvironment :: TypeEnvironment,
    -- | Top-level values whose scheme is known; grown SCC by SCC by the driver as components are
    -- checked, so a callee is registered before any caller is walked.
    valueEnvironment :: ValueEnvironment,
    -- | Locals in scope, keyed by 'LocalVariableId' (the identifier-resolved variable id). A local
    -- holds a 'Scheme' like a top-level value — usually non-generic, but a local @agent@ may declare
    -- generics, so explicit application works on locals too.
    locals :: Map LocalVariableId Scheme,
    -- | The attribute of the lexical scope the checker is currently inside (top-level public; a
    -- @private agent@ body raises it). Joined into every subtype comparison by the normalizer.
    world :: NormalizedAttribute,
    -- | The generic parameters currently in scope, keyed by id (an agent's / handler's declared
    -- generics, whose bounds @subtype@ consults). Held flat and handed to the normalizer / elaborator
    -- at the edge.
    genericsInScope :: Map GenericId GenericParameterInformation,
    jumps :: JumpContexts
  }

-- | A control transfer out of the current expression, classified by the construct that captures it: a
-- @return@ ('ReturnJump', captured by the enclosing agent), a @for@ @next@ / @break@ ('ForJump',
-- captured by the enclosing @for@), or a handler @next@ / @break@ ('HandlerJump', captured by the
-- enclosing request handler). A @use@ is not here — it already contributes an effect. Used to decide
-- whether a control-flow branch (a match arm, an @if@ branch) is /pure/: a branch that escapes via a
-- jump carries its value out bypassing the branch's value, so it is treated like an effect.
data JumpKind = ReturnJump | ForJump | HandlerJump
  deriving stock (Eq, Ord, Show)

-- | Per-walk mutable state: the accumulators an /inference scope/ collects into. Each sits at its
-- bottom outside its scope and is meaningful only inside the matching @with*Inference@ run, which
-- 'collecting' snapshots / resets / restores so a nested scope sees only its own contributions.
data CheckerState = CheckerState
  { -- | The union of every @return@ value in the enclosing agent / closure body (a 'withReturnInference'
    -- run), so an unannotated agent's return type is inferred from its @return@s as well as its block
    -- tail. Bottom outside an agent body.
    returnAccumulator :: NormalizedType,
    -- | The innermost @for@'s element values (its @next@ values and its body tail — a @for@ is a map) or
    -- a request handler's resume values (its handler @next@ values and its body tail, checked against the
    -- request return type at the edge). Bottom outside such a scope ('withNextInference').
    nextAccumulator :: NormalizedType,
    -- | The @break@ values of the innermost @for@ or handler — short-circuit results that bypass @then@
    -- and union straight into the construct's result. Bottom outside such a scope ('withBreakInference').
    breakAccumulator :: NormalizedType,
    -- | The union of every effect contribution in the innermost effect-collection scope (a
    -- 'withEffectInference' run): non-pure calls and @use@ statements emit into it. Bottom (pure)
    -- outside such a scope.
    effectAccumulator :: NormalizedEffect,
    -- | The kinds of jump that have escaped the current capture region (the dual of the value
    -- accumulators, for control flow). A jump statement adds its kind ('markJump'); a capturing
    -- construct removes the kind it consumes ('capturingJumps'); a branch reads what is left to decide
    -- its purity ('collectingJumps').
    escapingJumps :: Set JumpKind,
    -- | A monotonically increasing counter for minting fresh inference variables (metavariables)
    -- during generic-argument inference ('freshGenericId'). Threaded through the whole walk so two
    -- instantiations in one expression never collide.
    metavarCounter :: Int
  }
  deriving stock (Eq, Show)

-- | The initial state — every accumulator at its bottom (a join with anything is the other thing, so
-- a not-yet-walked scope starts collecting from there).
initialCheckerState :: CheckerState
initialCheckerState =
  CheckerState
    { returnAccumulator = bottomType,
      nextAccumulator = bottomType,
      breakAccumulator = bottomType,
      effectAccumulator = bottomEffect,
      escapingJumps = Set.empty,
      metavarCounter = 0
    }

-- | Mint a fresh inference variable id under the reserved 'inferenceModuleName', advancing the
-- per-walk counter. Used by generic-argument inference to instantiate a scheme's parameters as
-- metavariables; the result is always substituted away before it leaves the inference site.
freshGenericId :: Checker GenericId
freshGenericId = do
  next <- gets (.metavarCounter)
  modify (\state -> state {metavarCounter = next + 1})
  pure (GenericId inferenceModuleName next)

-- | The checker monad: read-only environment, 'Diagnostics' writer, 'CheckerState' state.
type Checker a = RWS CheckerEnvironment Diagnostics CheckerState a

-- | A fresh checker environment over the given type environment, with nothing else in scope. The
-- elaborate context the checker uses comes from 'typeEnvironment' ('TypeEnvironment.elaborateContext').
initialCheckerEnvironment :: TypeEnvironment -> CheckerEnvironment
initialCheckerEnvironment typeEnvironment =
  CheckerEnvironment
    { typeEnvironment = typeEnvironment,
      valueEnvironment = mempty,
      locals = mempty,
      world = bottomAttribute,
      genericsInScope = mempty,
      jumps = emptyJumpContexts
    }

runChecker :: CheckerEnvironment -> Checker a -> (a, Diagnostics)
runChecker environment action =
  let (result, _, diagnostics) = runRWS action environment initialCheckerState in (result, diagnostics)

------------------------------------------------------------------------------------------------
-- Normalizer bridging
------------------------------------------------------------------------------------------------

-- | Assemble the 'SubtypingContext' the normalizer runs against from the checker's flat state — the
-- nominal environments (from 'typeEnvironment'), the in-scope generics and the lexical 'world'. Built at
-- the edge rather than stored pre-built, so the checker keeps a single flat source of truth and the
-- normalizer always sees exactly the current world / generics.
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
-- the given source span. The normalizer is span-free (it operates over already-normalized types),
-- so we attach the call-site span at the boundary.
runNormalizer :: SourceSpan -> Normalizer a -> Checker a
runNormalizer sourceSpan action = do
  environment <- normalizerEnvironment
  let (result, _, errors) = runRWS action environment ()
  tell (foldMap (diagnosticAt sourceSpan . CompilerErrorType) errors)
  pure result

-- | Run an 'Elaborate' sub-action with the checker's elaborate context, forwarding its already
-- located diagnostics. Used to convert a 'SyntacticTypeExpression' into a 'SemanticType' /
-- 'SemanticEffect' / 'SemanticAttribute' inside an agent body — parameter annotations, @let@
-- annotations, etc. The two-step pattern is "elaborate to semantic, then 'normalizeType' /
-- 'normalizeEffect' through 'runNormalizer'".
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

-- | Raise the world by @attribute@ for the sub-action: every comparison inside observes the new
-- world. The lexical body of a @private agent@ uses this, joining its declared attribute in.
withWorld :: NormalizedAttribute -> Checker a -> Checker a
withWorld attribute = local raise
  where
    -- The signature disambiguates the record update: @world@ is a field of both 'CheckerEnvironment'
    -- and 'SubtypingContext'.
    raise :: CheckerEnvironment -> CheckerEnvironment
    raise environment = environment {world = joinAttribute environment.world attribute}

------------------------------------------------------------------------------------------------
-- Environment extension
------------------------------------------------------------------------------------------------

-- | Bring a local variable's scheme into scope for the sub-action.
withLocal :: LocalVariableId -> Scheme -> Checker a -> Checker a
withLocal variableId scheme =
  local (\environment -> environment {locals = Map.insert variableId scheme environment.locals})

-- | Bring a list of @(localId, scheme)@ pairs into scope for the sub-action — the multi-parameter
-- form of 'withLocal'. Used to bind every parameter of an agent / handler at once before the body
-- runs.
withParameters :: List (LocalVariableId, Scheme) -> Checker a -> Checker a
withParameters bindings continuation = foldr applyOne continuation bindings
  where
    applyOne (localId, scheme) = withLocal localId scheme

-- | Permanently register top-level values in the checker environment from this point onward, as the
-- driver iterates the value SCCs (the registration must persist for the rest of the walk). Each
-- callee component is registered before any caller component is walked.
extendValueEnvironment :: Map QualifiedName Scheme -> CheckerEnvironment -> CheckerEnvironment
extendValueEnvironment additions environment =
  environment {valueEnvironment = environment.valueEnvironment <> additions}

-- | Bring an in-scope generic parameter into scope for the sub-action (used while checking an
-- agent / handler with declared generics; the parameter's bound is consulted by 'subtype').
withGeneric :: GenericId -> GenericParameterInformation -> Checker a -> Checker a
withGeneric genericId info = local extend
  where
    -- The signature disambiguates the record update: @genericsInScope@ is a field of both
    -- 'CheckerEnvironment' and 'SubtypingContext'.
    extend :: CheckerEnvironment -> CheckerEnvironment
    extend environment = environment {genericsInScope = Map.insert genericId info environment.genericsInScope}

------------------------------------------------------------------------------------------------
-- Jump frames
------------------------------------------------------------------------------------------------

-- | Push a jump frame for the sub-action; 'local' pops it when the outer environment is restored.
pushJumpFrame :: JumpFrame -> Checker a -> Checker a
pushJumpFrame frame =
  local (\environment -> environment {jumps = JumpContexts {frames = frame : environment.jumps.frames}})

-- | Enter an agent / closure body: a @return@ inside now targets this body (the innermost 'ReturnFrame').
enterAgentBody :: Checker a -> Checker a
enterAgentBody = pushJumpFrame ReturnFrame

-- | Enter a @for@ body, so a @for@ @next@ / @break@ inside has a frame to target.
enterForBody :: Checker a -> Checker a
enterForBody = pushJumpFrame ForFrame

-- | Enter a request handler body: a handler @next@ / @break@ targets it, and a @return@ is blocked (the
-- frame is a barrier — a request handler body is deferred, so a @return@ may not escape to the enclosing
-- agent; only a nested closure's own 'ReturnFrame' catches one).
enterRequestHandler :: Checker a -> Checker a
enterRequestHandler = pushJumpFrame RequestHandlerFrame

-- | Enter a handler @then@ finalizer body: every jump is blocked (the @then@ runs once after the handler,
-- so a @return@ / @next@ / @break@ inside has no target and is reported misplaced).
enterHandlerThen :: Checker a -> Checker a
enterHandlerThen = pushJumpFrame HandlerThenFrame

------------------------------------------------------------------------------------------------
-- Inference scopes
--
-- An inference scope runs a sub-walk with one accumulator reset to its bottom, then reads back what
-- the walk collected and restores the outer value, so a nested scope sees only its own contributions.
-- 'collecting' is that pattern, once; 'accumulateInto' is the dual emit (union a contribution in).
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
-- @sourceSpan@). The dual of 'collecting': the emit sites feed a scope.
accumulateInto :: (TypeLattice a) => (CheckerState -> a) -> (a -> CheckerState -> CheckerState) -> SourceSpan -> a -> Checker ()
accumulateInto get put sourceSpan addition = do
  current <- gets get
  joined <- runNormalizer sourceSpan (union current addition)
  modify (put joined)

-- | Run an agent / closure body collecting the union of its @return@ values, so an unannotated agent's
-- return type is inferred from its @return@s in addition to its block tail. Scopes the accumulator to the
-- body, so a nested agent's @return@s do not leak out.
withReturnInference :: Checker a -> Checker (NormalizedType, a)
withReturnInference = collecting (.returnAccumulator) (\value state -> state {returnAccumulator = value}) bottomType

-- | Run a @for@ body or a request handler body collecting its @next@ / body-tail values — a @for@'s
-- inferred element type, or a request handler's resume values (checked against the request return type at
-- the edge). Scopes the accumulator to this construct.
withNextInference :: Checker a -> Checker (NormalizedType, a)
withNextInference = collecting (.nextAccumulator) (\value state -> state {nextAccumulator = value}) bottomType

-- | Run a @for@ body or a handler collecting its @break@ values — the short-circuit results that bypass
-- @then@ and union straight into the construct's result. Scopes the accumulator to this construct.
withBreakInference :: Checker a -> Checker (NormalizedType, a)
withBreakInference = collecting (.breakAccumulator) (\value state -> state {breakAccumulator = value}) bottomType

-- | Run an effect-collection scope (a handler request body, a @use@ continuation) returning its
-- inferred residual effect; the effects performed inside do not leak to the enclosing scope.
withEffectInference :: Checker a -> Checker (NormalizedEffect, a)
withEffectInference = collecting (.effectAccumulator) (\value state -> state {effectAccumulator = value}) bottomEffect

-- | A @return@ value joins the enclosing agent's inferred return type.
emitReturnType :: SourceSpan -> NormalizedType -> Checker ()
emitReturnType = accumulateInto (.returnAccumulator) (\value state -> state {returnAccumulator = value})

-- | A @next@ value (or a @for@ / request-handler body tail) joins the enclosing construct's @next@
-- channel — the inferred @for@ element type, or the resume values a request handler checks against its
-- request return type.
emitNextType :: SourceSpan -> NormalizedType -> Checker ()
emitNextType = accumulateInto (.nextAccumulator) (\value state -> state {nextAccumulator = value})

-- | A @break@ value joins the enclosing construct's short-circuit results (its @break@ channel — these
-- bypass @then@ and union straight into the result type).
emitBreakType :: SourceSpan -> NormalizedType -> Checker ()
emitBreakType = accumulateInto (.breakAccumulator) (\value state -> state {breakAccumulator = value})

-- | An effect contribution (a non-pure call, a @use@) joins the enclosing scope's inferred effect.
emitEffect :: SourceSpan -> NormalizedEffect -> Checker ()
emitEffect = accumulateInto (.effectAccumulator) (\value state -> state {effectAccumulator = value})

-- | Record that a jump of this kind has fired, so an enclosing branch that does not capture it sees
-- the branch as escaping (hence non-pure).
markJump :: JumpKind -> Checker ()
markJump kind = modify (\state -> state {escapingJumps = Set.insert kind state.escapingJumps})

-- | Run @action@ with the escaping-jumps set reset to empty, then restore the outer set joined with
-- @transform@ applied to whatever escaped inside, returning that inner set alongside the result. The
-- shared core of the two jump scopes (the dual of a value-inference scope, for control flow).
aroundJumps :: (Set JumpKind -> Set JumpKind) -> Checker a -> Checker (Set JumpKind, a)
aroundJumps transform action = do
  outer <- gets (.escapingJumps)
  modify (\state -> state {escapingJumps = Set.empty})
  result <- action
  inner <- gets (.escapingJumps)
  modify (\state -> state {escapingJumps = Set.union outer (transform inner)})
  pure (inner, result)

-- | Run the body of a construct that captures @captured@ jumps (a @for@ captures 'ForJump', a request
-- handler 'HandlerJump', an agent 'ReturnJump'): jumps of that kind raised inside it stop here, while
-- jumps of other kinds still escape to the enclosing scope.
capturingJumps :: JumpKind -> Checker a -> Checker a
capturingJumps captured action = snd <$> aroundJumps (Set.delete captured) action

-- | Run a control-flow branch (a match arm, an @if@ branch) and report whether any jump escaped it (so
-- the caller can treat an escaping branch as non-pure). The escaped jumps still propagate outward (a
-- @return@ in a match arm escapes the match too).
collectingJumps :: Checker a -> Checker (Bool, a)
collectingJumps action = do
  (inner, result) <- aroundJumps id action
  pure (not (Set.null inner), result)
