-- | The checker's runtime context (Phase C, "Katari.Typechecker"): the monad and the read-only
-- environment it threads. Per-kind checking ("Katari.Typechecker.Check", "Katari.Typechecker.Pattern")
-- reads from this; the driver ("Katari.Typechecker") seeds it and walks the value SCCs.
--
-- Two structural ideas organise this module:
--
--   * The /world/ — the attribute of the lexical scope the checker is currently inside. Top-level
--     starts public (bottom); a @private agent@ body raises it to private; a local agent declared in
--     a private world inherits the world (the value's outer attribute joins it). Every subtype
--     comparison goes through the normalizer which joins the world into both sides, so attribute
--     propagation is contextual, not pushed down.
--
--   * /Jump contexts/ — a stack of in-scope @return@ / @break@ / @next@ targets. A @return@
--     statement reads the enclosing agent's return type; a @break@ / @next@ reads the innermost
--     enclosing @for@ or @handler@ frame's expected type. Frames are pushed by 'withReturnTarget' /
--     'enterForBody' / 'pushHandleContext' on the way down (all through 'pushJumpFrame'), popped (by
--     'local') on the way back up.
module Katari.Typechecker.Context where

import Control.Monad.RWS.CPS (RWS, runRWS)
import Control.Monad.RWS.Class (MonadWriter (..), asks, gets, local, modify)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import GHC.List (List)
import Katari.Data.Environment
  ( GenericParameterInformation,
    Scheme,
    ValueEnvironment,
  )
import Katari.Data.Id (GenericId, LocalVariableId)
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
-- Jump contexts
------------------------------------------------------------------------------------------------

-- | The stack of jump targets in scope at one point of the walk, innermost first. A jump consults the
-- innermost frame of its own kind: a @return@ the innermost 'ReturnFrame' (the enclosing agent), a
-- @for@ @next@ / @break@ the innermost 'ForFrame', a handler @next@ / @break@ the innermost
-- 'HandlerFrame'. One uniform stack replaces three parallel fields; the accessors 'returnTarget',
-- 'insideForBody' and 'innermostHandler' project the frame each jump needs.
newtype JumpContexts = JumpContexts {frames :: List JumpFrame}
  deriving stock (Eq, Show)

-- | One enclosing jump target the walk has descended through. A 'ForFrame' carries no data: a @for@'s
-- element / break-result types are inferred into 'CheckerState' (reset per innermost @for@), so a
-- @next@ / @break@ needs only to know a @for@ encloses it.
data JumpFrame
  = ReturnFrame NormalizedType
  | ForFrame
  | HandlerFrame HandleContext
  deriving stock (Eq, Show)

emptyJumpContexts :: JumpContexts
emptyJumpContexts = JumpContexts {frames = []}

-- | What a @handler@'s request-handler bodies consult: the handler's overall result type @R@ (the
-- target of a @break@) and the expected value type of a @next@ in the current request handler.
data HandleContext = HandleContext
  { -- | The handler's overall result type @R@. A @break@ inside a request handler body yields @R@;
    -- so does the @then@ clause's body type.
    handlerResultType :: NormalizedType,
    -- | The expected type of @next e@ inside the current request handler body — the intercepted
    -- request's return type with the handler's generic arguments substituted in. One frame is
    -- pushed per request handler walk, so the innermost frame always carries the right value.
    currentRequestReturnType :: NormalizedType
  }
  deriving stock (Eq, Show)

-- | The innermost enclosing agent's @return@ target, if any. 'Nothing' at module top level — a stray
-- @return@ is diagnosed by the checker.
returnTarget :: JumpContexts -> Maybe NormalizedType
returnTarget contexts = listToMaybe [target | ReturnFrame target <- contexts.frames]

-- | Whether the walk is inside a @for@ body (so a @for@ @next@ / @break@ has a frame to target).
insideForBody :: JumpContexts -> Bool
insideForBody contexts = any isForFrame contexts.frames
  where
    isForFrame = \case
      ForFrame -> True
      _ -> False

-- | The innermost enclosing @handler@ frame, if any.
innermostHandler :: JumpContexts -> Maybe HandleContext
innermostHandler contexts = listToMaybe [context | HandlerFrame context <- contexts.frames]

------------------------------------------------------------------------------------------------
-- The checker monad
------------------------------------------------------------------------------------------------

-- | The checker's read-only environment.
data CheckerEnvironment = CheckerEnvironment
  { -- | The global type-level environment built by the env-build phase. Also carries the
    -- elaborator's signature registry ('elaborateContext'), so the checker can elaborate type /
    -- effect / attribute annotations encountered inside agent bodies.
    typeEnvironment :: TypeEnvironment,
    -- | Top-level values whose scheme is known; grown SCC by SCC by the driver as components are
    -- checked, so a callee is registered before any caller is walked.
    valueEnvironment :: ValueEnvironment,
    -- | Locals in scope, keyed by 'LocalVariableId' (the identifier-resolved variable id). A local
    -- holds a 'Scheme' like a top-level value — usually non-generic, but a local @agent@ may declare
    -- generics, so explicit application works on locals too.
    locals :: Map LocalVariableId Scheme,
    -- | The context the normalizer runs against: the nominal environment, the generics in scope (an
    -- agent's / handler's declared generics, whose bounds 'subtype' consults), and the lexical 'world'
    -- attribute (top-level public; a @private agent@ body raises it). Carried verbatim so the checker
    -- and the normalizer share one source of truth — 'normalizerEnvironment' is just its projection.
    subtyping :: SubtypingContext,
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
  { -- | What the innermost @for@ body has produced so far; bottom outside a @for@.
    forAccumulator :: ForAccumulator,
    -- | The union of every effect contribution in the innermost effect-collection scope (a
    -- 'withEffectInference' run): non-pure calls and @use@ statements emit into it. Bottom (pure)
    -- outside such a scope.
    effectAccumulator :: NormalizedEffect,
    -- | The union of every @return@ value in the enclosing agent body (a 'withReturnInference' run),
    -- so an unannotated agent's return type is inferred from its @return@s as well as its block tail.
    -- Bottom outside an agent body.
    returnAccumulator :: NormalizedType,
    -- | The kinds of jump that have escaped the current capture region (the dual of the value
    -- accumulators, for control flow). A jump statement adds its kind ('markJump'); a capturing
    -- construct removes the kind it consumes ('capturingJumps'); a branch reads what is left to decide
    -- its purity ('collectingJumps').
    escapingJumps :: Set JumpKind
  }
  deriving stock (Eq, Show)

-- | What a @for@ body produces, accumulated as the body is walked: the union of every @next@ value
-- (the inferred element type) and every @break@ value (the short-circuit results the @for@ may yield
-- in addition to its normal array / then result).
data ForAccumulator = ForAccumulator
  { nextElements :: NormalizedType,
    breakResults :: NormalizedType
  }
  deriving stock (Eq, Show)

emptyForAccumulator :: ForAccumulator
emptyForAccumulator = ForAccumulator {nextElements = bottomType, breakResults = bottomType}

-- | The initial state — every accumulator at its bottom (a join with anything is the other thing, so
-- a not-yet-walked scope starts collecting from there).
initialCheckerState :: CheckerState
initialCheckerState = CheckerState {forAccumulator = emptyForAccumulator, effectAccumulator = bottomEffect, returnAccumulator = bottomType, escapingJumps = Set.empty}

-- | The checker monad: read-only environment, 'Diagnostics' writer, 'CheckerState' state.
type Checker a = RWS CheckerEnvironment Diagnostics CheckerState a

-- | A fresh checker environment over the given type environment, with nothing else in scope. The
-- elaborate context the checker uses comes from 'typeEnvironment' ('TypeEnvironment.elaborateContext').
initialCheckerEnvironment :: TypeEnvironment -> CheckerEnvironment
initialCheckerEnvironment typeEnv =
  CheckerEnvironment
    { typeEnvironment = typeEnv,
      valueEnvironment = mempty,
      locals = mempty,
      subtyping =
        SubtypingContext
          { dataEnvironment = typeEnv.dataEnvironment,
            requestEnvironment = typeEnv.requestEnvironment,
            genericsInScope = mempty,
            world = bottomAttribute
          },
      jumps = emptyJumpContexts
    }

runChecker :: CheckerEnvironment -> Checker a -> (a, Diagnostics)
runChecker environment action =
  let (result, _, diagnostics) = runRWS action environment initialCheckerState in (result, diagnostics)

------------------------------------------------------------------------------------------------
-- Normalizer bridging
------------------------------------------------------------------------------------------------

-- | The normalizer runs against exactly the checker's embedded subtyping context, so @subtype@ /
-- @union@ / @intersect@ behave consistently inside and outside the checker.
normalizerEnvironment :: Checker NormalizerEnvironment
normalizerEnvironment = asks (.subtyping)

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
  generics <- asks (\environment -> environment.subtyping.genericsInScope)
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
currentWorld = asks (\environment -> environment.subtyping.world)

-- | Modify the embedded subtyping context for the sub-action.
overSubtyping :: (SubtypingContext -> SubtypingContext) -> Checker a -> Checker a
overSubtyping update = local (\environment -> environment {subtyping = update environment.subtyping})

-- | Raise the world by @attribute@ for the sub-action: every comparison inside observes the new
-- world. The lexical body of a @private agent@ uses this, joining its declared attribute in.
withWorld :: NormalizedAttribute -> Checker a -> Checker a
withWorld attribute = overSubtyping (\context -> context {world = joinAttribute context.world attribute})

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

-- | Bring a top-level (qualified) value into scope. The SCC driver uses this to grow the value
-- environment as each component is checked.
withValue :: QualifiedName -> Scheme -> Checker a -> Checker a
withValue qualifiedName scheme =
  local (\environment -> environment {valueEnvironment = Map.insert qualifiedName scheme environment.valueEnvironment})

-- | Permanently register a top-level value in the checker environment from this point onward.
-- 'withValue' scopes the registration to a sub-action; 'extendValueEnvironment' is the variant
-- used when iterating SCCs at the driver level (the registration must persist for the rest of the
-- walk, not just one sub-action).
extendValueEnvironment :: Map QualifiedName Scheme -> CheckerEnvironment -> CheckerEnvironment
extendValueEnvironment additions environment =
  environment {valueEnvironment = environment.valueEnvironment <> additions}

-- | The accumulated value environment of a checker environment. The driver reads it back after the
-- whole-program walk to hand every top-level callable's scheme to lowering (for schema building).
checkerValueEnvironment :: CheckerEnvironment -> ValueEnvironment
checkerValueEnvironment environment = environment.valueEnvironment

-- | Bring an in-scope generic parameter into scope for the sub-action (used while checking an
-- agent / handler with declared generics; the parameter's bound is consulted by 'subtype').
withGeneric :: GenericId -> GenericParameterInformation -> Checker a -> Checker a
withGeneric genericId info =
  overSubtyping (\context -> context {genericsInScope = Map.insert genericId info context.genericsInScope})

------------------------------------------------------------------------------------------------
-- Jump contexts
------------------------------------------------------------------------------------------------

-- | Push a jump frame for the sub-action; 'local' pops it when the outer environment is restored.
pushJumpFrame :: JumpFrame -> Checker a -> Checker a
pushJumpFrame frame =
  local (\environment -> environment {jumps = JumpContexts {frames = frame : environment.jumps.frames}})

-- | Enter an agent body: a @return@ inside now targets @target@ (the innermost 'ReturnFrame'), not the
-- enclosing agent's.
withReturnTarget :: NormalizedType -> Checker a -> Checker a
withReturnTarget target = pushJumpFrame (ReturnFrame target)

-- | Enter a @for@ body, so a @for@ @next@ / @break@ inside has a frame to target.
enterForBody :: Checker a -> Checker a
enterForBody = pushJumpFrame ForFrame

-- | Push a @handler@ frame for the sub-action.
pushHandleContext :: HandleContext -> Checker a -> Checker a
pushHandleContext context = pushJumpFrame (HandlerFrame context)

-- | Run a sub-action with no jump targets in scope, so a @return@ / @break@ / @next@ inside is
-- reported misplaced. A /deferred/ or /finalizer/ body uses this: a handler request body runs when the
-- handler is invoked, not where it is written, so it must not @return@ to the enclosing agent (it then
-- pushes only its own 'HandlerFrame' for its @break@ / @next@); a @then@ finalizer runs once after its
-- construct and permits no jumps at all.
withoutJumpTargets :: Checker a -> Checker a
withoutJumpTargets = local (\environment -> environment {jumps = emptyJumpContexts})

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

-- | Run a @for@ body collecting its inferred next-element and break-result types (see
-- 'ForAccumulator'); the effect accumulator is left untouched (a different scope axis).
withForInference :: Checker a -> Checker (NormalizedType, NormalizedType, a)
withForInference action = do
  (accumulator, result) <- collecting (.forAccumulator) (\value state -> state {forAccumulator = value}) emptyForAccumulator action
  pure (accumulator.nextElements, accumulator.breakResults, result)

-- | Run an effect-collection scope (a handler request body, a @use@ continuation) returning its
-- inferred residual effect; the effects performed inside do not leak to the enclosing scope.
withEffectInference :: Checker a -> Checker (NormalizedEffect, a)
withEffectInference = collecting (.effectAccumulator) (\value state -> state {effectAccumulator = value}) bottomEffect

-- | Run an agent body collecting the union of its @return@ values, so an unannotated agent's return
-- type is inferred from its @return@s in addition to its block tail. Scopes the accumulator to the
-- agent, so a nested agent's @return@s do not leak out.
withReturnInference :: Checker a -> Checker (NormalizedType, a)
withReturnInference = collecting (.returnAccumulator) (\value state -> state {returnAccumulator = value}) bottomType

-- | A @for@ body's @next@ value joins the inferred element type.
emitForNextType :: SourceSpan -> NormalizedType -> Checker ()
emitForNextType = accumulateInto (\state -> state.forAccumulator.nextElements) (\value state -> state {forAccumulator = state.forAccumulator {nextElements = value}})

-- | A @for@ body's @break@ value joins the short-circuit results.
emitForBreakType :: SourceSpan -> NormalizedType -> Checker ()
emitForBreakType = accumulateInto (\state -> state.forAccumulator.breakResults) (\value state -> state {forAccumulator = state.forAccumulator {breakResults = value}})

-- | An effect contribution (a non-pure call, a @use@) joins the enclosing scope's inferred effect.
emitEffect :: SourceSpan -> NormalizedEffect -> Checker ()
emitEffect = accumulateInto (.effectAccumulator) (\value state -> state {effectAccumulator = value})

-- | A @return@ value joins the enclosing agent's inferred return type.
emitReturnType :: SourceSpan -> NormalizedType -> Checker ()
emitReturnType = accumulateInto (.returnAccumulator) (\value state -> state {returnAccumulator = value})

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
