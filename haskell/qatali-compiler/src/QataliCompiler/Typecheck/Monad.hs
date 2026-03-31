{- | Checker monad and helpers for the Qatali type checker.

Provides the 'CheckM' monad, read-only environment, mutable state,
and all the utility operations needed by the checker and inference modules.
-}
module QataliCompiler.Typecheck.Monad (
    -- * Monad and environment
    CheckM,
    CheckEnv (..),
    CheckState (..),
    runCheck,
    runCheckWithDefs,
    runCheckWithInterfaces,

    -- * Error reporting
    emitError,

    -- * Effects
    addEffect,
    takeEffects,
    withFreshEffects,
    removeEffects,
    findEffectArgs,

    -- * Variable / type-variable scope
    lookupVar,
    lookupVarQualified,
    withBindings,
    withTypeVars,
    withContinueInfo,

    -- * Top-level value registration
    registerValueDef,
    getValueDefs,

    -- * Module scope
    withImportedModules,
    withCurrentModule,
    withModuleAlias,

    -- * Type definitions
    getTypeDefs,
    modifyTypeDefs,

    -- * Fresh variables (unknowns and generics)
    freshUnknown,
    freshGeneric,
    withBumpedLevel,

    -- * Constraints and assumptions
    addConstraint,
    addAssumption,
    takeConstraintsAndAssumptions,
    solveAndReport,
    addBoundAssumptions,
    addGenericInfo,

    -- * Trait resolution
    recordResolvedImpl,
    getResolvedImpls,

    -- * Literal inference (shared utility)
    inferLiteral,
) where

import           Control.Monad.Reader                  (ReaderT, asks, local,
                                                        runReaderT)
import           Control.Monad.State.Strict            (StateT, gets, modify,
                                                        runStateT)
import           Data.List.NonEmpty                    (toList)
import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as Map
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import qualified Data.Text                             as T

import           QataliCompiler.Diagnostic             (Diagnostic, mkError)
import           QataliCompiler.Name                   (ModuleName (..), Name (..),
                                                        QualifiedName (..))
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Syntax.Literal
import           QataliCompiler.Type.Defs              (ModuleInterface (..),
                                                        TypeDefs (..),
                                                        emptyTypeDefs)
import           QataliCompiler.Type.Env               (TyEnv)
import qualified QataliCompiler.Type.Env               as Env
import           QataliCompiler.Type.Normalize         (mergeNormEffect)
import           QataliCompiler.Type.NormalizedEffect    (NormalizedEffect (..),
                                                        NormalizedEffectRef (..))
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint  (Assumption, Constraint,
                                                        (?<:), withSpan)
import           QataliCompiler.TypeSolver.Solve       (SolveResult (..), solve)
import           QataliCompiler.TypeSolver.Types       (GenericInfo (..),
                                                        Level,
                                                        UnknownBounds (..),
                                                        emptyBounds)

-- =========================================================================
-- Checker monad
-- =========================================================================

-- | Read-only environment for the checker.
data CheckEnv = CheckEnv
    { ceValueEnv        :: !TyEnv
    -- ^ Variable -> Type bindings
    , ceTypeVars        :: !(Map Name Bound)
    -- ^ In-scope type variables with their bounds
    , ceInFnBody        :: !Bool
    -- ^ Whether we are directly inside a function body block (return allowed on last line)
    , ceContinueInfo    :: !(Maybe (Type, Type))
    -- ^ @Just (effectReturnTy, handleResultTy)@ when inside a handle case body
    , ceCurrentModule   :: !(Maybe ModuleName)
    -- ^ The module currently being checked
    , ceImportedModules :: !(Map ModuleName ModuleInterface)
    -- ^ Imported module interfaces keyed by full module name
    , ceModuleAliases   :: !(Map Name ModuleName)
    -- ^ Single-segment alias → full module name (from @import "m" as alias@)
    }

-- | Mutable state for the checker.
data CheckState = CheckState
    { csErrors        :: ![Diagnostic]
    , csEffects       :: !NormalizedEffect
    , csNextFresh     :: !Int
    , csTypeDefs      :: !TypeDefs
    , csConstraints   :: ![Constraint]
    , csAssumptions   :: !(Set Assumption)
    , csUnknownBounds :: !(Map Name UnknownBounds)
    , csGenerics      :: !(Map Name GenericInfo)
    , csCurrentLevel  :: !Level
    , csValueDefs     :: !(Map Name (Type, Bool))
    -- ^ Top-level value definitions: (type, isPub)
    , csResolvedImpls :: !(Map SrcSpan Name)
    -- ^ Trait call sites resolved to impl function names.
    -- Key is the SrcSpan of the call expression.
    }

type CheckM = ReaderT CheckEnv (StateT CheckState (Either [Diagnostic]))

runCheck :: TypeDefs -> CheckM a -> Either [Diagnostic] a
runCheck defs m = fmap (\(a, _, _) -> a) (runCheckWithDefs defs m)

-- | Like 'runCheck', but also returns the final 'TypeDefs' and resolved impls.
runCheckWithDefs :: TypeDefs -> CheckM a -> Either [Diagnostic] (a, TypeDefs, Map SrcSpan Name)
runCheckWithDefs defs m = do
    (result, finalState) <- runStateT (runReaderT m env0) state0
    case csErrors finalState of
        []   -> Right (result, csTypeDefs finalState, csResolvedImpls finalState)
        errs -> Left (reverse errs)
  where
    env0 = CheckEnv Env.empty Map.empty False Nothing Nothing Map.empty Map.empty
    state0 = mkState0 defs

-- | Run the checker with pre-loaded module interfaces.
-- Returns @(result, moduleInterface, finalTypeDefs, resolvedImpls)@.
runCheckWithInterfaces
    :: TypeDefs            -- ^ merged type defs from already-compiled modules
    -> [ModuleInterface]   -- ^ interfaces of imported modules
    -> ModuleName          -- ^ name of the module being checked
    -> CheckM a
    -> Either [Diagnostic] (a, ModuleInterface, TypeDefs, Map SrcSpan Name)
runCheckWithInterfaces defs ifaces mn m = do
    let importMap = Map.fromList [(miModuleName i, i) | i <- ifaces]
    let env0 = CheckEnv
            { ceValueEnv        = Env.empty
            , ceTypeVars        = Map.empty
            , ceInFnBody        = False
            , ceContinueInfo    = Nothing
            , ceCurrentModule   = Just mn
            , ceImportedModules = importMap
            , ceModuleAliases   = Map.empty
            }
    (result, finalState) <- runStateT (runReaderT m env0) (mkState0 defs)
    case csErrors finalState of
        [] -> do
            let pubValues = Map.map fst $ Map.filter snd (csValueDefs finalState)
            let iface = ModuleInterface
                    { miModuleName = mn
                    , miTypeDefs   = csTypeDefs finalState
                    , miValues     = pubValues
                    }
            Right (result, iface, csTypeDefs finalState, csResolvedImpls finalState)
        errs -> Left (reverse errs)

mkState0 :: TypeDefs -> CheckState
mkState0 defs = CheckState
    { csErrors        = []
    , csEffects       = NEffPure
    , csNextFresh     = 0
    , csTypeDefs      = defs
    , csConstraints   = []
    , csAssumptions   = Set.empty
    , csUnknownBounds = Map.empty
    , csGenerics      = Map.empty
    , csCurrentLevel  = 0
    , csValueDefs     = Map.empty
    , csResolvedImpls = Map.empty
    }

-- =========================================================================
-- Monad helpers
-- =========================================================================

emitError :: SrcSpan -> Text -> CheckM ()
emitError sp msg = modify (\s -> s { csErrors = mkError sp msg : csErrors s })

addEffect :: NormalizedEffect -> CheckM ()
addEffect eff = modify (\s -> s { csEffects = mergeNormEffect (csEffects s) eff })

takeEffects :: CheckM NormalizedEffect
takeEffects = do
    eff <- gets csEffects
    modify (\s -> s { csEffects = NEffPure })
    pure eff

withFreshEffects :: CheckM a -> CheckM (a, NormalizedEffect)
withFreshEffects m = do
    saved <- gets csEffects
    modify (\s -> s { csEffects = NEffPure })
    result <- m
    eff <- takeEffects
    modify (\s -> s { csEffects = saved })
    pure (result, eff)

removeEffects :: Set Name -> NormalizedEffect -> NormalizedEffect
removeEffects names = \case
    NEffPure    -> NEffPure
    NEffImpure  -> NEffImpure
    NEffVar n   -> NEffVar n
    NEffSet refs ->
        let remaining = filter (\r -> not (Set.member (nerName r) names)) refs
         in if null remaining then NEffPure else NEffSet remaining

lookupVar :: Name -> CheckM (Maybe Type)
lookupVar n = asks (Env.lookupType n . ceValueEnv)

-- | Look up a possibly-qualified variable.
-- Unqualified: check local env.
-- Qualified: resolve module (via alias or direct name) then look up in its interface.
lookupVarQualified :: QualifiedName -> CheckM (Maybe Type)
lookupVarQualified (QualifiedName Nothing n) = lookupVar n
lookupVarQualified (QualifiedName (Just modRef) n) = do
    aliases  <- asks ceModuleAliases
    imported <- asks ceImportedModules
    -- Try single-segment alias first
    let segs = toList (segments modRef)
    let resolved = case segs of
            [aliasName] -> case Map.lookup (Name aliasName) aliases of
                Just fullMod -> Map.lookup fullMod imported
                Nothing      -> Map.lookup modRef imported
            _ -> Map.lookup modRef imported
    case resolved of
        Just iface -> pure (Map.lookup n (miValues iface))
        Nothing    -> pure Nothing

withBindings :: [(Name, Type)] -> CheckM a -> CheckM a
withBindings bs = local (\env -> env { ceValueEnv = Env.extendMany bs (ceValueEnv env) })

withTypeVars :: [(Name, Bound)] -> CheckM a -> CheckM a
withTypeVars tvs = local (\env -> env { ceTypeVars = Map.fromList tvs `Map.union` ceTypeVars env })

withContinueInfo :: Type -> Type -> CheckM a -> CheckM a
withContinueInfo effRetTy handleResTy =
    local (\env -> env { ceContinueInfo = Just (effRetTy, handleResTy) })

-- =========================================================================
-- Top-level value registration
-- =========================================================================

registerValueDef :: Name -> Type -> Bool -> CheckM ()
registerValueDef name ty isPub =
    modify (\s -> s { csValueDefs = Map.insert name (ty, isPub) (csValueDefs s) })

getValueDefs :: CheckM (Map Name (Type, Bool))
getValueDefs = gets csValueDefs

-- =========================================================================
-- Module scope helpers
-- =========================================================================

withImportedModules :: Map ModuleName ModuleInterface -> CheckM a -> CheckM a
withImportedModules mods =
    local (\env -> env { ceImportedModules = mods `Map.union` ceImportedModules env })

withCurrentModule :: ModuleName -> CheckM a -> CheckM a
withCurrentModule mn =
    local (\env -> env { ceCurrentModule = Just mn })

withModuleAlias :: Name -> ModuleName -> CheckM a -> CheckM a
withModuleAlias alias mn =
    local (\env -> env { ceModuleAliases = Map.insert alias mn (ceModuleAliases env) })

-- =========================================================================
-- Type definitions
-- =========================================================================

getTypeDefs :: CheckM TypeDefs
getTypeDefs = gets csTypeDefs

modifyTypeDefs :: (TypeDefs -> TypeDefs) -> CheckM ()
modifyTypeDefs f = modify (\s -> s { csTypeDefs = f (csTypeDefs s) })

-- | Find type arguments for a named effect from a NormalizedEffect.
findEffectArgs :: Name -> NormalizedEffect -> [Type]
findEffectArgs name = \case
    NEffSet refs ->
        case filter (\r -> nerName r == name) refs of
            (r:_) -> nerArgs r
            []    -> []
    _ -> []

-- =========================================================================
-- Fresh variables
-- =========================================================================

-- | Generate a fresh unknown variable.
freshUnknown :: CheckM Type
freshUnknown = do
    n <- gets csNextFresh
    modify (\s -> s { csNextFresh = csNextFresh s + 1 })
    let name = Name (T.pack ("_u" ++ show n))
    modify (\s -> s { csUnknownBounds = Map.insertWith (\_ old -> old) name emptyBounds (csUnknownBounds s) })
    pure (TUnknownVar name)

-- | Introduce a fresh generic variable at the current level with the given bound.
freshGeneric :: Bound -> CheckM Name
freshGeneric bound = do
    n <- gets csNextFresh
    modify (\s -> s { csNextFresh = n + 1 })
    let name = Name (T.pack ("_g" ++ show n))
    addGenericInfo name bound
    addBoundAssumptions name bound
    pure name

-- | Run an action with the generics level bumped by 1.
withBumpedLevel :: CheckM a -> CheckM a
withBumpedLevel m = do
    modify (\s -> s { csCurrentLevel = csCurrentLevel s + 1 })
    result <- m
    modify (\s -> s { csCurrentLevel = csCurrentLevel s - 1 })
    pure result

-- =========================================================================
-- Constraints and assumptions
-- =========================================================================

addConstraint :: SrcSpan -> Type -> Type -> CheckM ()
addConstraint sp actual expected =
    modify (\s -> s { csConstraints = withSpan sp actual expected : csConstraints s })

addAssumption :: Type -> Type -> CheckM ()
addAssumption lower upper =
    modify (\s -> s { csAssumptions = Set.insert (lower ?<: upper) (csAssumptions s) })

takeConstraintsAndAssumptions :: CheckM ([Constraint], Set Assumption, Map Name UnknownBounds, Map Name GenericInfo)
takeConstraintsAndAssumptions = do
    cs <- gets csConstraints
    as <- gets csAssumptions
    ub <- gets csUnknownBounds
    gi <- gets csGenerics
    modify (\s -> s
        { csConstraints   = []
        , csAssumptions   = Set.empty
        , csUnknownBounds = Map.empty
        , csGenerics      = Map.empty
        })
    pure (cs, as, ub, gi)

solveAndReport :: SrcSpan -> CheckM ()
solveAndReport declAnn = do
    (cs, as, ub, gi) <- takeConstraintsAndAssumptions
    defs <- getTypeDefs
    case solve defs gi as cs ub of
        SolveSuccess -> pure ()
        SolveContradiction sp msg ->
            let reportSpan = case sp of
                    NoSpan -> declAnn
                    _      -> sp
            in emitError reportSpan msg

addBoundAssumptions :: Name -> Bound -> CheckM ()
addBoundAssumptions name = \case
    BoundSub ty  -> addAssumption (TVar name) ty
    BoundSup ty  -> addAssumption ty (TVar name)
    BoundIs  ty  -> do
        addAssumption (TVar name) ty
        addAssumption ty (TVar name)
    BoundNone    -> pure ()

addGenericInfo :: Name -> Bound -> CheckM ()
addGenericInfo name bound = do
    lvl <- gets csCurrentLevel
    let info = GenericInfo { giName = name, giLevel = lvl, giBound = bound }
    modify (\s -> s { csGenerics = Map.insert name info (csGenerics s) })

-- =========================================================================
-- Literal types
-- =========================================================================

-- =========================================================================
-- Trait resolution
-- =========================================================================

recordResolvedImpl :: SrcSpan -> Name -> CheckM ()
recordResolvedImpl sp fnName =
    modify (\s -> s { csResolvedImpls = Map.insert sp fnName (csResolvedImpls s) })

getResolvedImpls :: CheckM (Map SrcSpan Name)
getResolvedImpls = gets csResolvedImpls

-- =========================================================================
-- Literal types
-- =========================================================================

inferLiteral :: Literal -> Type
inferLiteral = \case
    LitInteger n -> TLit (LitIntegerType n)
    LitNumber d  -> TLit (LitNumberType d)
    LitString s  -> TLit (LitStringType s)
    LitBoolean b -> TLit (LitBooleanType b)
    LitNull      -> TPrim PrimNull
