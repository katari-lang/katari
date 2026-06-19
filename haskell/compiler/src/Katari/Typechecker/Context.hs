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
--     enclosing @for@ or @handler@ frame's expected type. Frames are pushed by 'pushForContext' /
--     'pushHandleContext' and 'withReturnTarget' on the way down, popped (by 'local') on the way
--     back up.
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

-- | The jump targets in scope at one point of the walk: the enclosing agent's @return@, whether the
-- walk is inside a @for@ body, and the stack of enclosing @handler@ frames. A jump consults the
-- relevant one ('returnTarget' for @return@, 'inForBody' for a @for@ @next@ / @break@, the head of
-- 'handleContexts' for a handler @next@ / @break@).
data JumpContexts = JumpContexts
  { -- | The current agent's return type. 'Nothing' at module top level — a stray @return@ is
    -- diagnosed by the checker.
    returnTarget :: Maybe NormalizedType,
    -- | Whether the walk is inside a @for@ body. A @for@'s element / break-result types are inferred
    -- into 'CheckerState' (reset per innermost @for@), so a @next@ / @break@ needs only to know a @for@
    -- encloses it — no per-frame data, hence a flag rather than a stack.
    inForBody :: Bool,
    -- | Enclosing @handler@ bodies and the request handlers nested within, innermost first.
    handleContexts :: List HandleContext
  }
  deriving stock (Eq, Show)

emptyJumpContexts :: JumpContexts
emptyJumpContexts =
  JumpContexts
    { returnTarget = Nothing,
      inForBody = False,
      handleContexts = []
    }

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
    returnAccumulator :: NormalizedType
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
initialCheckerState = CheckerState {forAccumulator = emptyForAccumulator, effectAccumulator = bottomEffect, returnAccumulator = bottomType}

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

-- | Bring an in-scope generic parameter into scope for the sub-action (used while checking an
-- agent / handler with declared generics; the parameter's bound is consulted by 'subtype').
withGeneric :: GenericId -> GenericParameterInformation -> Checker a -> Checker a
withGeneric genericId info =
  overSubtyping (\context -> context {genericsInScope = Map.insert genericId info context.genericsInScope})

------------------------------------------------------------------------------------------------
-- Jump contexts
------------------------------------------------------------------------------------------------

-- | Replace any outer return target with @target@ for the sub-action. Used when entering an agent
-- body: an inner agent's @return@ targets its own body, not the enclosing one.
withReturnTarget :: NormalizedType -> Checker a -> Checker a
withReturnTarget target =
  local (\environment -> environment {jumps = environment.jumps {returnTarget = Just target}})

-- | Mark the sub-action as being inside a @for@ body; the flag is restored when 'local' restores the
-- outer environment.
enterForBody :: Checker a -> Checker a
enterForBody =
  local (\environment -> environment {jumps = environment.jumps {inForBody = True}})

-- | Push a @handler@ frame for the sub-action.
pushHandleContext :: HandleContext -> Checker a -> Checker a
pushHandleContext context =
  local (\environment -> environment {jumps = environment.jumps {handleContexts = context : environment.jumps.handleContexts}})

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
