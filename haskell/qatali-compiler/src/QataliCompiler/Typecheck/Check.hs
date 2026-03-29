{- | Type checker for the Qatali language (HM-inference style).

Constraint-based approach:
  * Each complex expression introduces fresh unknown variables
  * Constraints are generated between inner and outer types
  * The solver resolves all unknowns and checks satisfiability

Nominal types:
  * No structural objects or tuples — all compound types go through @data@ declarations
  * @EConstruct@ builds record data types
  * @PCon@ matches tuple data types positionally; @PRecord@ matches record data types by name
  * Pattern matching introduces Generics (with levels) and Assumptions per NominalTypes.md

Effect handling:
  * Effects bubble up from inner expressions to the nearest enclosing @fn@
  * @handle@ blocks catch specified effects; uncaught effects continue upward
-}
module QataliCompiler.Typecheck.Check (
    -- * Entry point
    checkModule,
    inferExpr,

    -- * Checker monad
    CheckM,
    CheckEnv (..),
    CheckState (..),
    runCheck,
    runCheckWithDefs,
) where

import           Control.Monad                         (forM, forM_, unless)
import           Control.Monad.Reader                  (ReaderT, asks, local,
                                                        runReaderT)
import           Control.Monad.State.Strict            (StateT, gets, modify,
                                                        runStateT)
import           Data.Map.Strict                       (Map)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import           Data.Set                              (Set)
import qualified Data.Set                              as Set
import           Data.Text                             (Text)
import qualified Data.Text                             as T

import           QataliCompiler.Diagnostic             (Diagnostic, mkError)
import           QataliCompiler.Name                   (Name (..),
                                                        QualifiedName (..))
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Syntax.Literal
import           QataliCompiler.Type.Env               (TyEnv)
import qualified QataliCompiler.Type.Env               as Env
import           QataliCompiler.Type.Normalize         (DataDef (..),
                                                        DataKind (..),
                                                        EffectDef (..),
                                                        TypeDefs (..),
                                                        TypeSynDef (..),
                                                        normalizeEffect)
import           QataliCompiler.Type.NormalizedType    (NormalizedEffect (..),
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
    { ceValueEnv     :: !TyEnv
    -- ^ Variable -> Type bindings
    , ceTypeVars     :: !(Map Name Bound)
    -- ^ In-scope type variables with their bounds
    , ceInFnBody     :: !Bool
    -- ^ Whether we are directly inside a function body block (return allowed on last line)
    , ceContinueInfo :: !(Maybe (Type, Type))
    -- ^ @Just (effectReturnTy, handleResultTy)@ when inside a handle case body
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
    }

type CheckM = ReaderT CheckEnv (StateT CheckState (Either [Diagnostic]))

runCheck :: TypeDefs -> CheckM a -> Either [Diagnostic] a
runCheck defs m = fmap fst (runCheckWithDefs defs m)

-- | Like 'runCheck', but also returns the final 'TypeDefs' (with all
-- data\/type\/effect definitions accumulated during checking).
runCheckWithDefs :: TypeDefs -> CheckM a -> Either [Diagnostic] (a, TypeDefs)
runCheckWithDefs defs m = do
    (result, finalState) <- runStateT (runReaderT m env0) state0
    case csErrors finalState of
        []   -> Right (result, csTypeDefs finalState)
        errs -> Left (reverse errs)
  where
    env0 = CheckEnv Env.empty Map.empty False Nothing
    state0 = CheckState
        { csErrors        = []
        , csEffects       = NEffPure
        , csNextFresh     = 0
        , csTypeDefs      = defs
        , csConstraints   = []
        , csAssumptions   = Set.empty
        , csUnknownBounds = Map.empty
        , csGenerics      = Map.empty
        , csCurrentLevel  = 0
        }

-- =========================================================================
-- Monad helpers
-- =========================================================================

emitError :: SrcSpan -> Text -> CheckM ()
emitError sp msg = modify (\s -> s { csErrors = mkError sp msg : csErrors s })

addEffect :: NormalizedEffect -> CheckM ()
addEffect eff = modify (\s -> s { csEffects = mergeEffect (csEffects s) eff })

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

mergeEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
mergeEffect a b =
    case (a, b) of
        (NEffPure, b')           -> b'
        (a', NEffPure)           -> a'
        (NEffImpure, _)          -> NEffImpure
        (_, NEffImpure)          -> NEffImpure
        (NEffSet a', NEffSet b') -> NEffSet (nubByName (a' ++ b'))
  where
    nubByName [] = []
    nubByName (x:xs) = x : nubByName (filter (\y -> nerName y /= nerName x) xs)

removeEffects :: Set Name -> NormalizedEffect -> NormalizedEffect
removeEffects names = \case
    NEffPure    -> NEffPure
    NEffImpure  -> NEffImpure
    NEffSet refs ->
        let remaining = filter (\r -> not (Set.member (nerName r) names)) refs
         in if null remaining then NEffPure else NEffSet remaining

lookupVar :: Name -> CheckM (Maybe Type)
lookupVar n = asks (Env.lookupType n . ceValueEnv)

withBindings :: [(Name, Type)] -> CheckM a -> CheckM a
withBindings bs = local (\env -> env { ceValueEnv = Env.extendMany bs (ceValueEnv env) })

withTypeVars :: [(Name, Bound)] -> CheckM a -> CheckM a
withTypeVars tvs = local (\env -> env { ceTypeVars = Map.fromList tvs `Map.union` ceTypeVars env })

withContinueInfo :: Type -> Type -> CheckM a -> CheckM a
withContinueInfo effRetTy handleResTy =
    local (\env -> env { ceContinueInfo = Just (effRetTy, handleResTy) })

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
-- Resolving source-level types to internal types
-- =========================================================================

resolveTyExpr :: TyExpr ann -> CheckM Type
resolveTyExpr = \case
    TyVar _ name -> pure (TVar name)
    TyCon _ qn   -> resolveTypeName qn
    TyApp _ base args -> do
        baseTy <- resolveTyExpr base
        argTys <- mapM resolveTyExpr args
        case baseTy of
            TData name [] -> pure (TData name argTys)
            _             -> pure baseTy
    TyFun _ params ret mEff -> do
        params' <- forM params $ \(name, tyE) -> do
            ty <- resolveTyExpr tyE
            pure (FunParam name ty)
        ret' <- resolveTyExpr ret
        eff' <- case mEff of
            Nothing -> pure EffPure
            Just e  -> resolveEffectExpr e
        pure (TFun params' ret' eff')
    TyArray _ elem' -> do
        ty <- resolveTyExpr elem'
        pure (TArray ty)
    TyUnion _ a b -> do
        a' <- resolveTyExpr a
        b' <- resolveTyExpr b
        pure (TUnion a' b')
    TyIntersect _ a b -> do
        a' <- resolveTyExpr a
        b' <- resolveTyExpr b
        pure (TIntersection a' b')
    TyLit _ lit -> pure (inferLiteral lit)

resolveTypeName :: QualifiedName -> CheckM Type
resolveTypeName qn = do
    let name = qnName qn
    tvs <- asks ceTypeVars
    defs <- getTypeDefs
    if Map.member name tvs
        then pure (TVar name)
        else case Map.lookup name (tdTypes defs) of
            Just tsd | null (tsParams tsd) -> pure (tsBody tsd)
            _ -> case Map.lookup name (tdData defs) of
                Just _  -> pure (TData name [])
                Nothing -> case Map.lookup name (tdEffects defs) of
                    Just _ -> pure (TData name [])
                    Nothing ->
                        case unName name of
                            "unknown" -> pure TUnknown
                            "never"   -> pure TNever
                            "integer" -> pure (TPrim PrimInteger)
                            "number"  -> pure (TPrim PrimNumber)
                            "string"  -> pure (TPrim PrimString)
                            "boolean" -> pure (TPrim PrimBoolean)
                            "null"    -> pure (TPrim PrimNull)
                            _         -> pure TUnknown

resolveEffectExpr :: TyExpr ann -> CheckM Effect
resolveEffectExpr = \case
    TyCon _ qn -> do
        let name = qnName qn
        case unName name of
            "pure"   -> pure EffPure
            "impure" -> pure EffImpure
            _        -> pure (EffSingle name [])
    TyApp _ base args -> do
        baseTy <- resolveEffectExpr base
        argTys <- mapM resolveTyExpr args
        case baseTy of
            EffSingle name [] -> pure (EffSingle name argTys)
            _                 -> pure baseTy
    TyUnion _ a b -> do
        a' <- resolveEffectExpr a
        b' <- resolveEffectExpr b
        pure (EffUnion [a', b'])
    TyVar _ name -> pure (EffVar name)
    _ -> pure EffImpure

-- =========================================================================
-- Resolving source-level type params
-- =========================================================================

resolveSrcTypeParams :: [SrcTypeParam ann] -> CheckM [(Name, Bound)]
resolveSrcTypeParams = mapM $ \stp -> do
    bound <- case stpBound stp of
        Nothing                 -> pure BoundNone
        Just (SrcBoundSub _ te) -> BoundSub <$> resolveTyExpr te
        Just (SrcBoundSup _ te) -> BoundSup <$> resolveTyExpr te
        Just (SrcBoundIs  _ te) -> BoundIs  <$> resolveTyExpr te
    pure (stpName stp, bound)

resolveSrcDataTypeParams :: [SrcDataTypeParam ann] -> CheckM [(Name, Variance, Bound)]
resolveSrcDataTypeParams = mapM $ \sdtp -> do
    bound <- case sdtpBound sdtp of
        Nothing                 -> pure BoundNone
        Just (SrcBoundSub _ te) -> BoundSub <$> resolveTyExpr te
        Just (SrcBoundSup _ te) -> BoundSup <$> resolveTyExpr te
        Just (SrcBoundIs  _ te) -> BoundIs  <$> resolveTyExpr te
    let var = resolveSrcVariance (sdtpVariance sdtp)
    pure (sdtpName sdtp, var, bound)

resolveSrcVariance :: SrcVariance -> Variance
resolveSrcVariance = \case
    SrcOut   -> Covariant
    SrcIn    -> Contravariant
    SrcInOut -> Bivariant
    SrcNone  -> Invariant

-- =========================================================================
-- Module checking
-- =========================================================================

checkModule :: Module SrcSpan -> CheckM ()
checkModule m = do
    registerDecls (modDecls m)
    mapM_ checkDecl (modDecls m)

registerDecls :: [Decl SrcSpan] -> CheckM ()
registerDecls decls = forM_ decls $ \case
    DeclType _ name stps body -> do
        tvBindings <- resolveSrcTypeParams stps
        bodyTy <- withTypeVars tvBindings $ resolveTyExpr body
        let tsd = TypeSynDef
                { tsParams = map (\(n, b) -> TypeParam n b) tvBindings
                , tsBody   = bodyTy
                }
        modifyTypeDefs $ \td -> td { tdTypes = Map.insert name tsd (tdTypes td) }

    DeclData _ name sdtps declKind fields -> do
        paramInfo <- resolveSrcDataTypeParams sdtps
        let tvBindings = map (\(n, _, b) -> (n, b)) paramInfo
        fieldTys <- withTypeVars tvBindings $ forM fields $ \(fname, ftyE) -> do
            fty <- resolveTyExpr ftyE
            pure (fname, fty)
        let paramNames = map (\(n, _, _) -> n) paramInfo
        let params = map (\(_, v, _) -> DataTypeParam { dtpVariance = v }) paramInfo
        let bounds = map (\(_, _, b) -> b) paramInfo
        let kind = case declKind of
                DeclRecord -> DataRecord
                DeclTuple  -> DataTuple
        let dd = DataDef
                { ddKind       = kind
                , ddParamNames = paramNames
                , ddParams     = params
                , ddBounds     = bounds
                , ddFields     = fieldTys
                }
        modifyTypeDefs $ \td -> td { tdData = Map.insert name dd (tdData td) }

    DeclEffect _ name sdtps fields retTyE -> do
        paramInfo <- resolveSrcDataTypeParams sdtps
        let tvBindings = map (\(n, _, b) -> (n, b)) paramInfo
        fieldTys <- withTypeVars tvBindings $ forM fields $ \(fname, ftyE) -> do
            fty <- resolveTyExpr ftyE
            pure (fname, fty)
        retTy <- withTypeVars tvBindings $ resolveTyExpr retTyE
        let paramNames = map (\(n, _, _) -> n) paramInfo
        let params = map (\(_, v, _) -> DataTypeParam { dtpVariance = v }) paramInfo
        let bounds = map (\(_, _, b) -> b) paramInfo
        let ed = EffectDef
                { edParamNames = paramNames
                , edParams   = params
                , edBounds   = bounds
                , edFields   = fieldTys
                , edReturnTy = retTy
                }
        modifyTypeDefs $ \td -> td { tdEffects = Map.insert name ed (tdEffects td) }

    _ -> pure ()

checkDecl :: Decl SrcSpan -> CheckM ()
checkDecl = \case
    DeclLet ann _target stps mTyAnn body -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            forM_ tvBindings $ \(n, bound) -> do
                addBoundAssumptions n bound
                addGenericInfo n bound
            (bodyTy, _bodyEff) <- withFreshEffects $ inferExpr body
            case mTyAnn of
                Just tyAnn -> do
                    annTy <- resolveTyExpr tyAnn
                    addConstraint ann bodyTy annTy
                Nothing -> pure ()
            solveAndReport ann

    DeclFn ann _name stps params mRetTy fnBody -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            forM_ tvBindings $ \(n, bound) -> do
                addBoundAssumptions n bound
                addGenericInfo n bound
            paramBindings <- forM params $ \p -> do
                ty <- resolveTyExpr (paramType p)
                pure (paramName p, ty)
            withBindings paramBindings $ do
                (bodyTy, _bodyEff) <- withFreshEffects $ inferFnBody fnBody
                case mRetTy of
                    Just retAnn -> do
                        retTy <- resolveTyExpr retAnn
                        addConstraint ann bodyTy retTy
                    Nothing -> pure ()
                solveAndReport ann

    DeclImport {} -> pure ()
    DeclType {} -> pure ()
    DeclData {} -> pure ()
    DeclEffect {} -> pure ()

-- =========================================================================
-- Expression type inference (HM-style: generate unknowns + constraints)
-- =========================================================================

inferExpr :: Expr SrcSpan -> CheckM Type
inferExpr = \case
    ELit _ lit -> pure (inferLiteral lit)

    EVar ann qn -> do
        mTy <- lookupVar (qnName qn)
        case mTy of
            Just ty -> pure ty
            Nothing -> do
                emitError ann ("unbound variable: " <> unName (qnName qn))
                pure TUnknown

    EApp ann fun tyArgExprs argExprs -> do
        funTy <- inferExpr fun
        tyArgs <- mapM resolveTyExpr tyArgExprs
        argTys <- mapM inferExpr argExprs
        resultTy <- freshUnknown
        -- Apply explicit type arguments if provided
        appliedFunTy <- applyTypeArgs ann funTy tyArgs
        -- Constraint: appliedFunTy <: (argTys -> resultTy with impure)
        let paramFPs = zipWith (\i t -> FunParam (Name (T.pack ("_" ++ show i))) t)
                               [0::Int ..] argTys
        addConstraint ann appliedFunTy (TFun paramFPs resultTy EffImpure)
        -- Effect propagation: if the function type is known, merge its effect
        case appliedFunTy of
            TFun _ _ eff -> do
                defs <- getTypeDefs
                addEffect (normalizeEffect defs eff)
            _ -> pure ()
        pure resultTy

    EFn ann stps params mRetTy fnBody -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            paramBindings <- forM params $ \p -> do
                ty <- resolveTyExpr (paramType p)
                pure (paramName p, ty)
            let paramTypes = map (\(n, t) -> FunParam n t) paramBindings
            withBindings paramBindings $ do
                (bodyTy, bodyEff) <- withFreshEffects $ inferFnBody fnBody
                retTy <- case mRetTy of
                    Just retAnn -> do
                        rt <- resolveTyExpr retAnn
                        addConstraint ann bodyTy rt
                        pure rt
                    Nothing -> pure bodyTy
                pure (TFun paramTypes retTy (denormalizeEffect bodyEff))

    EIf _ann cond thn mEls -> do
        _ <- inferExpr cond
        thnTy <- inferExpr thn
        case mEls of
            Just els -> do
                elsTy <- inferExpr els
                pure (TUnion thnTy elsTy)
            Nothing -> pure thnTy

    EBlock _ stmts ->
        local (\env -> env { ceInFnBody = False }) $ inferBlock stmts

    EMatch _ann scrut arms -> do
        scrutTy <- inferExpr scrut
        resultTy <- freshUnknown
        forM_ arms $ \arm -> do
            bindings <- inferPattern scrutTy (maPat arm)
            armTy <- withBindings bindings $ inferExpr (maBody arm)
            addConstraint (maAnn arm) armTy resultTy
        pure resultTy

    EHandle ann expr cases mRet -> do
        -- 1. Infer the handled expression's type and effects
        (exprTy, exprEff) <- withFreshEffects $ inferExpr expr

        -- 2. Caught effect names
        let caughtNames = Set.fromList (map hcEffect cases)

        -- 3. Propagate uncaught effects upward
        addEffect (removeEffects caughtNames exprEff)

        -- 4. Fresh unknown for handle result type
        handleResultTy <- freshUnknown

        -- 5. Check return clause
        case mRet of
            Just hr -> do
                retBodyTy <- withBindings [(hrParam hr, exprTy)] $
                    inferExpr (hrBody hr)
                addConstraint (hrAnn hr) retBodyTy handleResultTy
            Nothing ->
                -- No return clause: expr type = handle result type
                addConstraint ann exprTy handleResultTy

        -- 6. Check each handle case
        defs <- getTypeDefs
        forM_ cases $ \hc -> do
            case Map.lookup (hcEffect hc) (tdEffects defs) of
                Just ed -> do
                    -- a. Get type args from accumulated effects
                    let effectArgs = findEffectArgs (hcEffect hc) exprEff
                    -- b. Substitution: param names → type args
                    let subst = Map.fromList (zip (edParamNames ed) effectArgs)
                    -- c. Substitute into field types
                    let fieldTys = map (substituteTVars subst . snd) (edFields ed)
                    -- d. Substitute into effect return type (continue's param type)
                    let effRetTy = substituteTVars subst (edReturnTy ed)
                    -- e. Infer pattern bindings
                    bindings <- concat <$>
                        zipWithM inferPattern fieldTys (hcParams hc)
                    -- f. Check case body with continue info
                    caseTy <- withContinueInfo effRetTy handleResultTy $
                        withBindings bindings $
                            inferExpr (hcBody hc)
                    -- g. Case body type <: handle result type
                    addConstraint (hcAnn hc) caseTy handleResultTy
                Nothing ->
                    emitError (hcAnn hc)
                        ("unknown effect in handle: " <> unName (hcEffect hc))

        pure handleResultTy

    EConstruct ann qn fieldExprs -> do
        defs <- getTypeDefs
        let conName = qnName qn
        case Map.lookup conName (tdData defs) of
            Just dd -> do
                case ddKind dd of
                    DataTuple -> do
                        emitError ann ("cannot use record construction syntax for tuple data type: " <> unName conName)
                        pure TUnknown
                    DataRecord -> do
                        freshArgs <- forM (ddParamNames dd) $ \_ -> freshUnknown
                        let subst = Map.fromList (zip (ddParamNames dd) freshArgs)
                        let declFieldNames = Set.fromList (map fst (ddFields dd))
                        let exprFieldNames = Set.fromList (map fst fieldExprs)
                        unless (declFieldNames == exprFieldNames) $
                            emitError ann $ "field mismatch for " <> unName conName
                                <> ": expected " <> T.pack (show (Set.toList (Set.map unName declFieldNames)))
                                <> ", got " <> T.pack (show (Set.toList (Set.map unName exprFieldNames)))
                        let declFieldMap = Map.fromList (ddFields dd)
                        forM_ fieldExprs $ \(fname, fexpr) -> do
                            fexprTy <- inferExpr fexpr
                            case Map.lookup fname declFieldMap of
                                Just declFTy -> do
                                    let expectedTy = substituteTVars subst declFTy
                                    addConstraint ann fexprTy expectedTy
                                Nothing -> pure ()
                        pure (TData conName freshArgs)
            Nothing -> do
                emitError ann ("unknown data type: " <> unName conName)
                pure TUnknown

    EArray ann elems -> do
        elemTy <- freshUnknown
        forM_ elems $ \case
            AElem e -> do
                eTy <- inferExpr e
                addConstraint ann eTy elemTy
            ASpread e -> do
                eTy <- inferExpr e
                addConstraint ann eTy (TArray elemTy)
        pure (TArray elemTy)

    EIndex ann arr idx -> do
        arrTy <- inferExpr arr
        idxTy <- inferExpr idx
        elemTy <- freshUnknown
        addConstraint ann arrTy (TArray elemTy)
        addConstraint ann idxTy (TPrim PrimInteger)
        pure elemTy

    EReturn _ mExpr -> do
        case mExpr of
            Just e  -> inferExpr e
            Nothing -> pure (TPrim PrimNull)

    ETemplateLit _ _ -> pure (TPrim PrimString)

    EBinOp ann op lhs rhs -> inferBinOp ann op lhs rhs

    EUnaryOp ann op expr -> inferUnaryOp ann op expr

    EContinue ann arg -> do
        mInfo <- asks ceContinueInfo
        case mInfo of
            Nothing -> do
                emitError ann "continue can only be used inside a handle case body"
                _ <- inferExpr arg
                pure TUnknown
            Just (effRetTy, handleResTy) -> do
                argTy <- inferExpr arg
                addConstraint ann argTy effRetTy
                pure handleResTy

-- =========================================================================
-- Function body / block inference
-- =========================================================================

inferFnBody :: FnBody SrcSpan -> CheckM Type
inferFnBody = \case
    FnExpr e -> inferExpr e
    FnBlock _ stmts ->
        local (\env -> env { ceInFnBody = True }) $ inferBlock stmts

inferBlock :: [Stmt SrcSpan] -> CheckM Type
inferBlock stmts = do
    inFn <- asks ceInFnBody
    validateReturns inFn stmts
    go stmts
  where
    go [] = pure (TPrim PrimNull)
    go [StmtExpr e] = inferExpr e
    go [StmtReturn _ mE] = case mE of
        Just e  -> inferExpr e
        Nothing -> pure (TPrim PrimNull)
    go (stmt:rest) = case stmt of
        StmtExpr e -> do
            _ <- inferExpr e
            go rest
        StmtLet stmtAnn target mTyAnn val -> do
            valTy <- inferExpr val
            varTy <- case mTyAnn of
                Just tyAnn -> do
                    annTy <- resolveTyExpr tyAnn
                    addConstraint stmtAnn valTy annTy
                    pure annTy
                Nothing -> do
                    u <- freshUnknown
                    addConstraint stmtAnn valTy u
                    pure u
            bindings <- letTargetBindings target varTy
            withBindings bindings $ go rest
        StmtReturn _ mE -> do
            case mE of
                Just e  -> inferExpr e
                Nothing -> pure (TPrim PrimNull)

validateReturns :: Bool -> [Stmt SrcSpan] -> CheckM ()
validateReturns inFn stmts = do
    forM_ (safeInit stmts) $ \case
        StmtReturn ann _ ->
            emitError ann "return can only appear as the last statement of a function body"
        _ -> pure ()
    case safeLast stmts of
        Just (StmtReturn ann _) | not inFn ->
            emitError ann "return is not allowed here; only in function body"
        _ -> pure ()
  where
    safeInit [] = []
    safeInit xs = init xs
    safeLast []     = Nothing
    safeLast xs     = Just (last xs)

letTargetBindings :: LetTarget SrcSpan -> Type -> CheckM [(Name, Type)]
letTargetBindings target ty =
    case target of
        LetName name -> pure [(name, ty)]
        LetPat pat   -> inferPattern ty pat

-- =========================================================================
-- Type argument application
-- =========================================================================

-- | Apply explicit type arguments to a type, substituting generics and
-- generating bound-check constraints.
applyTypeArgs :: SrcSpan -> Type -> [Type] -> CheckM Type
applyTypeArgs _ann ty [] = pure ty
applyTypeArgs ann ty tyArgs = do
    tvs <- asks ceTypeVars
    let tvNames = Map.keys tvs
    if length tyArgs > length tvNames
        then do
            emitError ann $ "too many type arguments: expected "
                <> T.pack (show (length tvNames))
                <> ", got " <> T.pack (show (length tyArgs))
            pure ty
        else do
            let subst = Map.fromList (zip tvNames tyArgs)
            forM_ (zip tvNames tyArgs) $ \(tvName, tyArg) ->
                case Map.lookup tvName tvs of
                    Just (BoundSub bound) -> addConstraint ann tyArg bound
                    Just (BoundSup bound) -> addConstraint ann bound tyArg
                    Just (BoundIs  bound) -> do
                        addConstraint ann tyArg bound
                        addConstraint ann bound tyArg
                    _                     -> pure ()
            pure (substituteTVars subst ty)

-- =========================================================================
-- Pattern type inference (Generics + Assumptions per NominalTypes.md)
-- =========================================================================

-- | Infer variable bindings from a pattern matched against a scrutinee type.
--
-- For constructor patterns (PCon, PRecord), this introduces fresh Generics
-- for the data type's type parameters and adds Assumptions:
--   * @DataType\<G1, ...\> \<: scrutTy@
--   * @G_i \<: bound_i@  (from data type's declared bounds)
inferPattern :: Type -> Pat SrcSpan -> CheckM [(Name, Type)]
inferPattern scrutTy = \case
    PVar _ name -> pure [(name, scrutTy)]
    PLit _ _    -> pure []
    PWild _     -> pure []

    PCon ann qn pats -> do
        defs <- getTypeDefs
        let conName = qnName qn
        case Map.lookup conName (tdData defs) of
            Just dd -> withBumpedLevel $ do
                -- 1. Introduce a Generic for each type parameter
                gNames <- forM (ddBounds dd) $ \bound ->
                    freshGeneric bound
                -- 2. Assumption: DataType<G1, ...> <: scrutTy
                let constructedTy = TData conName (map TVar gNames)
                addAssumption constructedTy scrutTy
                -- 3. Substitute generics into field types
                let subst = Map.fromList (zip (ddParamNames dd) (map TVar gNames))
                let fieldTys = map (substituteTVars subst . snd) (ddFields dd)
                -- 4. Recurse into sub-patterns
                concat <$> zipWithM inferPattern fieldTys pats
            Nothing -> do
                emitError ann ("unknown data type in pattern: " <> unName conName)
                concat <$> mapM (inferPattern TUnknown) pats

    PRecord ann qn fieldPats -> do
        defs <- getTypeDefs
        let conName = qnName qn
        case Map.lookup conName (tdData defs) of
            Just dd -> withBumpedLevel $ do
                -- 1. Introduce a Generic for each type parameter
                gNames <- forM (ddBounds dd) $ \bound ->
                    freshGeneric bound
                -- 2. Assumption: DataType<G1, ...> <: scrutTy
                let constructedTy = TData conName (map TVar gNames)
                addAssumption constructedTy scrutTy
                -- 3. Build substituted field map
                let subst = Map.fromList (zip (ddParamNames dd) (map TVar gNames))
                let declFieldMap = Map.fromList
                        [(n, substituteTVars subst t) | (n, t) <- ddFields dd]
                -- 4. Match fields by name
                fieldBindings <- forM fieldPats $ \(fname, pat) -> do
                    let fTy = fromMaybe TUnknown (Map.lookup fname declFieldMap)
                    inferPattern fTy pat
                pure (concat fieldBindings)
            Nothing -> do
                emitError ann ("unknown data type in pattern: " <> unName conName)
                concat <$> mapM (inferPattern TUnknown . snd) fieldPats

    PArray pAnn spreadPat -> do
        elemTy <- freshUnknown
        addConstraint pAnn scrutTy (TArray elemTy)
        inferSpreadPat (repeat elemTy) spreadPat

-- | Infer bindings from a spread pattern.
inferSpreadPat :: [Type] -> SpreadPat SrcSpan -> CheckM [(Name, Type)]
inferSpreadPat tys sp = do
    let nBefore = length (spBefore sp)
    let nAfter  = length (spAfter sp)
    let beforeTys = take nBefore tys
    let afterTys  = drop (max 0 (length tys - nAfter)) tys
    beforeBindings <- concat <$> zipWithM inferPattern beforeTys (spBefore sp)
    afterBindings  <- concat <$> zipWithM inferPattern afterTys (spAfter sp)
    spreadBinding <- case spSpread sp of
        Nothing -> pure []
        Just (_, pat) -> do
            let midTys = drop nBefore (take (max 0 (length tys - nAfter)) tys)
            let spreadTy = case midTys of
                    []  -> TArray TUnknown
                    [t] -> TArray t
                    _   -> TArray (foldl1 TUnion midTys)
            inferPattern spreadTy pat
    pure (beforeBindings ++ spreadBinding ++ afterBindings)

zipWithM :: Monad m => (a -> b -> m c) -> [a] -> [b] -> m [c]
zipWithM f xs ys = mapM (uncurry f) (zip xs ys)

-- =========================================================================
-- Binary / Unary operators
-- =========================================================================

inferBinOp :: SrcSpan -> BinOp -> Expr SrcSpan -> Expr SrcSpan -> CheckM Type
inferBinOp ann op lhs rhs = do
    lhsTy <- inferExpr lhs
    rhsTy <- inferExpr rhs
    case op of
        OpAdd  -> numericOp lhsTy rhsTy
        OpSub  -> numericOp lhsTy rhsTy
        OpMul  -> numericOp lhsTy rhsTy
        OpDiv  -> numericOp lhsTy rhsTy
        OpMod  -> numericOp lhsTy rhsTy
        OpEq   -> pure (TPrim PrimBoolean)
        OpNeq  -> pure (TPrim PrimBoolean)
        OpLt   -> pure (TPrim PrimBoolean)
        OpLe   -> pure (TPrim PrimBoolean)
        OpGt   -> pure (TPrim PrimBoolean)
        OpGe   -> pure (TPrim PrimBoolean)
        OpAnd  -> do
            addConstraint ann lhsTy (TPrim PrimBoolean)
            addConstraint ann rhsTy (TPrim PrimBoolean)
            pure (TPrim PrimBoolean)
        OpOr   -> do
            addConstraint ann lhsTy (TPrim PrimBoolean)
            addConstraint ann rhsTy (TPrim PrimBoolean)
            pure (TPrim PrimBoolean)
        OpConcat -> do
            addConstraint ann lhsTy (TPrim PrimString)
            addConstraint ann rhsTy (TPrim PrimString)
            pure (TPrim PrimString)
  where
    numericOp l r = do
        addConstraint ann l (TPrim PrimNumber)
        addConstraint ann r (TPrim PrimNumber)
        pure (TPrim PrimNumber)

inferUnaryOp :: SrcSpan -> UnaryOp -> Expr SrcSpan -> CheckM Type
inferUnaryOp ann op expr = do
    exprTy <- inferExpr expr
    case op of
        OpNeg -> do
            addConstraint ann exprTy (TPrim PrimNumber)
            pure (TPrim PrimNumber)
        OpNot -> do
            addConstraint ann exprTy (TPrim PrimBoolean)
            pure (TPrim PrimBoolean)

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

-- =========================================================================
-- Effect denormalization
-- =========================================================================

denormalizeEffect :: NormalizedEffect -> Effect
denormalizeEffect = \case
    NEffPure -> EffPure
    NEffImpure -> EffImpure
    NEffSet refs -> case refs of
        []  -> EffPure
        [r] -> EffSingle (nerName r) (nerArgs r)
        rs  -> EffUnion (map (\r -> EffSingle (nerName r) (nerArgs r)) rs)
