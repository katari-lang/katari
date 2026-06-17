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
import Data.Text (Text)
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
    NormalizedKindedType,
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
    NormalizerEnvironment (..),
    joinAttribute,
  )

------------------------------------------------------------------------------------------------
-- Jump contexts
------------------------------------------------------------------------------------------------

-- | The stack of jump targets in scope at one point of the walk: the enclosing agent's @return@,
-- and any number of nested @for@ / @handler@ frames. A jump statement consults the appropriate top
-- frame ('returnTarget' for @return@, head of 'forContexts' for @next@ / @break@ inside a @for@,
-- head of 'handleContexts' for @next@ / @break@ inside a request handler body).
data JumpContexts = JumpContexts
  { -- | The current agent's return type. 'Nothing' at module top level — a stray @return@ is
    -- diagnosed by the checker.
    returnTarget :: Maybe NormalizedType,
    -- | Enclosing @for@ bodies, innermost first.
    forContexts :: List ForContext,
    -- | Enclosing @handler@ bodies and the request handlers nested within, innermost first.
    handleContexts :: List HandleContext
  }
  deriving stock (Eq, Show)

emptyJumpContexts :: JumpContexts
emptyJumpContexts =
  JumpContexts
    { returnTarget = Nothing,
      forContexts = [],
      handleContexts = []
    }

-- | What a @for@ body's @next@ and @break@ expect.
data ForContext = ForContext
  { -- | The element type the @for@ emits per iteration; each @next@ value must be a subtype.
    nextElementType :: NormalizedType,
    -- | The @for@ expression's overall result type that @break@ yields.
    breakResultType :: NormalizedType
  }
  deriving stock (Eq, Show)

-- | What a @handler@ body and its request handlers expect: the handler's overall result type @R@
-- and residual effect @E@, plus the substitution of every request the handler intercepts (so
-- @next@'s value type inside @request foo(...) { ... }@ is @foo@'s return type instantiated with
-- those arguments).
data HandleContext = HandleContext
  { -- | The handler's overall result type @R@. A @break@ inside a request handler body yields @R@;
    -- so does the @then@ clause's body type.
    handlerResultType :: NormalizedType,
    -- | The residual effect @E@ the handler exposes; the continuation's effect is @E ∪ handled@.
    handlerResidualEffect :: NormalizedEffect,
    -- | The requests this handler intercepts, with their normalized argument substitution.
    handledRequests :: Map QualifiedName (Map Text NormalizedKindedType),
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
    -- | The generic parameters in scope (an agent's / handler's declared generics). The normalizer
    -- consults their declared upper bounds during subtype.
    genericsInScope :: Map GenericId GenericParameterInformation,
    -- | The attribute of the lexical scope we are inside. Top-level is the bottom (public); a
    -- @private agent@ body raises it; subtype joins it into both sides.
    world :: NormalizedAttribute,
    jumps :: JumpContexts
  }

-- | Per-walk mutable state.
--
--   * 'forBodyAccumulator' — the union of every @next@ value type seen so far inside the
--     innermost enclosing @for@ body, used to infer the for expression's element type. Outside
--     any for body it sits at 'bottomType' and is meaningless; 'withForInference' is the only
--     entry that observes it.
--   * 'effectAccumulator' — the union of every effect contribution seen so far inside the
--     innermost enclosing /effect-collection scope/ (a 'withEffectInference' run). Non-pure calls
--     and 'use' statements emit into it, so the scope reads back the body's inferred effect.
--     Outside an inference scope it sits at 'bottomEffect' (pure).
--
-- Other walks (ordinary subtype checks) ignore these slots. Both are scoped via their respective
-- @with*Inference@ helpers, which snapshot/restore around the inner walk so a nested scope sees
-- only its own contributions.
data CheckerState = CheckerState
  { forBodyAccumulator :: NormalizedType,
    effectAccumulator :: NormalizedEffect
  }
  deriving stock (Eq, Show)

-- | The initial state — both accumulators at their bottoms (a join with anything is the other
-- thing, so a not-yet-walked scope starts collecting from there).
initialCheckerState :: CheckerState
initialCheckerState =
  CheckerState
    { forBodyAccumulator = bottomType,
      effectAccumulator = bottomEffect
    }

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
      genericsInScope = mempty,
      world = bottomAttribute,
      jumps = emptyJumpContexts
    }

runChecker :: CheckerEnvironment -> Checker a -> (a, Diagnostics)
runChecker environment action =
  let (result, _, diagnostics) = runRWS action environment initialCheckerState in (result, diagnostics)

------------------------------------------------------------------------------------------------
-- Normalizer bridging
------------------------------------------------------------------------------------------------

-- | The 'NormalizerEnvironment' projected from the current checker environment. The normalizer
-- shares the world and the generics-in-scope, so @subtype@ / @union@ / @intersect@ behave
-- consistently inside and outside the checker.
normalizerEnvironment :: Checker NormalizerEnvironment
normalizerEnvironment = do
  typeEnv <- asks (.typeEnvironment)
  generics <- asks (.genericsInScope)
  currentWorld <- asks (.world)
  pure
    NormalizerEnvironment
      { dataEnvironment = typeEnv.dataEnvironment,
        requestEnvironment = typeEnv.requestEnvironment,
        genericsInScope = generics,
        world = currentWorld
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

-- | Raise the world by @attribute@ for the sub-action: every comparison inside observes the new
-- world. The lexical body of a @private agent@ uses this, joining its declared attribute in.
--
-- 'world' is shared with 'NormalizerEnvironment' under DuplicateRecordFields, so the record is
-- rebuilt explicitly rather than record-updated (same workaround as
-- 'Katari.Typechecker.Environment.stampBound' — the @{world = ...}@ update is ambiguous).
withWorld :: NormalizedAttribute -> Checker a -> Checker a
withWorld attribute = local (\environment -> rebuildWithWorld environment (joinAttribute environment.world attribute))

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
--
-- 'genericsInScope' is also shared with 'NormalizerEnvironment'; explicit rebuild for the same
-- reason as 'withWorld' (see comment there).
withGeneric :: GenericId -> GenericParameterInformation -> Checker a -> Checker a
withGeneric genericId info =
  local (\environment -> rebuildWithGenerics environment (Map.insert genericId info environment.genericsInScope))

------------------------------------------------------------------------------------------------
-- Jump contexts
------------------------------------------------------------------------------------------------

-- | Replace any outer return target with @target@ for the sub-action. Used when entering an agent
-- body: an inner agent's @return@ targets its own body, not the enclosing one.
withReturnTarget :: NormalizedType -> Checker a -> Checker a
withReturnTarget target =
  local (\environment -> environment {jumps = environment.jumps {returnTarget = Just target}})

-- | Push a @for@ frame for the sub-action; it is popped automatically when 'local' restores the
-- outer environment.
pushForContext :: ForContext -> Checker a -> Checker a
pushForContext context =
  local (\environment -> environment {jumps = environment.jumps {forContexts = context : environment.jumps.forContexts}})

-- | Push a @handler@ frame for the sub-action.
pushHandleContext :: HandleContext -> Checker a -> Checker a
pushHandleContext context =
  local (\environment -> environment {jumps = environment.jumps {handleContexts = context : environment.jumps.handleContexts}})

------------------------------------------------------------------------------------------------
-- For-body next-type inference
------------------------------------------------------------------------------------------------

-- | Run @action@ with a fresh 'forBodyAccumulator' (bottom) and return both the action's result
-- and the accumulator's final value — the inferred next-element type of the for body. The outer
-- state's accumulator is saved before the action and restored after, so a nested for body sees
-- only its own contributions. The 'effectAccumulator' is left untouched (different scope axis).
--
-- The for body walker accumulates each @forNext@ / @forBreak@ value's type into the slot via
-- 'Katari.Typechecker.Check.emitForNextType'; after the body walk, the slot holds the union of
-- every contributed type, which becomes the homogeneous element type of the for expression's
-- result array.
withForInference :: Checker a -> Checker (NormalizedType, a)
withForInference action = do
  saved <- gets (.forBodyAccumulator)
  modify (\s -> s {forBodyAccumulator = bottomType})
  result <- action
  inferred <- gets (.forBodyAccumulator)
  modify (\s -> s {forBodyAccumulator = saved})
  pure (inferred, result)

-- | Read the current 'forBodyAccumulator'. Reserved for the for body walker;
-- ordinary expression walks should not consult this.
getForBodyAccumulator :: Checker NormalizedType
getForBodyAccumulator = gets (.forBodyAccumulator)

-- | Replace the 'forBodyAccumulator' with a new value (typically the join of the old value with a
-- forNext / forBreak contribution).
setForBodyAccumulator :: NormalizedType -> Checker ()
setForBodyAccumulator newValue =
  modify (\s -> s {forBodyAccumulator = newValue})

------------------------------------------------------------------------------------------------
-- Effect aggregation
------------------------------------------------------------------------------------------------

-- | Run @action@ with a fresh 'effectAccumulator' (bottom) and return both the action's result
-- and the accumulator's final value — the inferred residual effect of the walked scope. The outer
-- state is saved before the action and restored after, so the inner effects do not leak out
-- (used to isolate handler request bodies and @use@ continuations: the requests they perform are
-- handled within and don't propagate to the enclosing agent's effect).
withEffectInference :: Checker a -> Checker (NormalizedEffect, a)
withEffectInference action = do
  saved <- gets (.effectAccumulator)
  modify (\s -> s {effectAccumulator = bottomEffect})
  result <- action
  inferred <- gets (.effectAccumulator)
  modify (\s -> s {effectAccumulator = saved})
  pure (inferred, result)

getEffectAccumulator :: Checker NormalizedEffect
getEffectAccumulator = gets (.effectAccumulator)

setEffectAccumulator :: NormalizedEffect -> Checker ()
setEffectAccumulator newValue =
  modify (\s -> s {effectAccumulator = newValue})

------------------------------------------------------------------------------------------------
-- Record-update workarounds
--
-- Two of 'CheckerEnvironment''s field names ('world', 'genericsInScope') collide with
-- 'NormalizerEnvironment'. Under DuplicateRecordFields, the @{world = ...}@ / @{genericsInScope = ...}@
-- record updates are flagged ambiguous (-Wambiguous-fields), so each is rebuilt by an explicit
-- constructor instead — same workaround as 'Katari.Typechecker.Environment.stampBound'.
------------------------------------------------------------------------------------------------

rebuildWithWorld :: CheckerEnvironment -> NormalizedAttribute -> CheckerEnvironment
rebuildWithWorld environment newWorld =
  CheckerEnvironment
    { typeEnvironment = environment.typeEnvironment,
      valueEnvironment = environment.valueEnvironment,
      locals = environment.locals,
      genericsInScope = environment.genericsInScope,
      world = newWorld,
      jumps = environment.jumps
    }

rebuildWithGenerics :: CheckerEnvironment -> Map GenericId GenericParameterInformation -> CheckerEnvironment
rebuildWithGenerics environment newGenerics =
  CheckerEnvironment
    { typeEnvironment = environment.typeEnvironment,
      valueEnvironment = environment.valueEnvironment,
      locals = environment.locals,
      genericsInScope = newGenerics,
      world = environment.world,
      jumps = environment.jumps
    }
