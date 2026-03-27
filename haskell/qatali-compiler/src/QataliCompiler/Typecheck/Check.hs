{- | Type checker for the Qatali language.

Based on subtyping (not HM unification).  Types are mostly explicit:
  * Function parameter types must be annotated
  * Let bindings may omit type annotations (inferred from RHS)
  * Generics must be explicitly applied at call sites

The checker:
  1. Registers all type\/data\/effect declarations into 'TypeDefs'
  2. Checks each value declaration's body against its (optional) annotation
  3. For expressions, derives types bottom-up
  4. Collects effects from function bodies (propagated to enclosing fn)

Effect handling:
  * Effects bubble up from inner expressions to the nearest enclosing @fn@
  * @handle@ blocks catch specified effects; uncaught effects continue upward
  * @continue@ in a handler resumes with the effect's return type
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
import           QataliCompiler.SrcLoc                 (SrcSpan)
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Syntax.Literal
import           QataliCompiler.Type.Env               (TyEnv)
import qualified QataliCompiler.Type.Env               as Env
import           QataliCompiler.Type.Normalize         (DataDef (..),
                                                        EffectDef (..),
                                                        TypeDefs (..),
                                                        TypeSynDef (..),
                                                        normalizeEffect)
import           QataliCompiler.Type.NormalizedType    (NormalizedEffect (..),
                                                        NormalizedEffectRef (..))
import           QataliCompiler.Type.Type
import           QataliCompiler.TypeSolver.Constraint  (Assumption, Constraint,
                                                        (?<:))
import           QataliCompiler.TypeSolver.Solve       (SolveResult (..), solve)

-- =========================================================================
-- Checker monad
-- =========================================================================

-- | Read-only environment for the checker.
data CheckEnv = CheckEnv
    { ceValueEnv :: !TyEnv
    -- ^ Variable → Type bindings
    , ceTypeVars :: !(Map Name Bound)
    -- ^ In-scope type variables with their bounds
    , ceInFnBody :: !Bool
    -- ^ Whether we are directly inside a function body block (return allowed on last line)
    }

-- | Mutable state for the checker.
data CheckState = CheckState
    { csErrors      :: ![Diagnostic]
    -- ^ Accumulated errors
    , csEffects     :: !NormalizedEffect
    -- ^ Effects accumulated in the current function body
    , csNextFresh   :: !Int
    -- ^ For fresh name generation
    , csTypeDefs    :: !TypeDefs
    -- ^ All type/data/effect definitions (mutable — updated by registerDecls)
    , csConstraints :: !(Set Constraint)
    -- ^ Subtype constraints accumulated for the current declaration
    , csAssumptions :: !(Set Assumption)
    -- ^ Assumptions (generics bounds) for the current declaration
    }

type CheckM = ReaderT CheckEnv (StateT CheckState (Either [Diagnostic]))

runCheck :: TypeDefs -> CheckM a -> Either [Diagnostic] a
runCheck defs m = do
    (result, finalState) <- runStateT (runReaderT m env0) state0
    case csErrors finalState of
        []   -> Right result
        errs -> Left (reverse errs)
  where
    env0 = CheckEnv Env.empty Map.empty False
    state0 = CheckState [] NEffPure 0 defs Set.empty Set.empty

-- | Emit a type error.
emitError :: SrcSpan -> Text -> CheckM ()
emitError sp msg = modify (\s -> s { csErrors = mkError sp msg : csErrors s })

-- | Collect an effect into the current function's effect set.
addEffect :: NormalizedEffect -> CheckM ()
addEffect eff = modify (\s -> s { csEffects = mergeEffect (csEffects s) eff })

-- | Reset effect accumulator and return what was collected.
takeEffects :: CheckM NormalizedEffect
takeEffects = do
    eff <- gets csEffects
    modify (\s -> s { csEffects = NEffPure })
    pure eff

-- | Run a sub-check with a fresh effect accumulator, returning the collected effects.
withFreshEffects :: CheckM a -> CheckM (a, NormalizedEffect)
withFreshEffects m = do
    saved <- gets csEffects
    modify (\s -> s { csEffects = NEffPure })
    result <- m
    eff <- takeEffects
    modify (\s -> s { csEffects = saved })
    pure (result, eff)

-- | Merge two normalized effects (union), deduplicating same-name effects.
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

-- | Remove effects with given names from an effect set.
removeEffects :: Set Name -> NormalizedEffect -> NormalizedEffect
removeEffects names = \case
    NEffPure    -> NEffPure
    NEffImpure  -> NEffImpure
    NEffSet refs ->
        let remaining = filter (\r -> not (Set.member (nerName r) names)) refs
         in if null remaining then NEffPure else NEffSet remaining

-- | Look up a variable's type.
lookupVar :: Name -> CheckM (Maybe Type)
lookupVar n = asks (Env.lookupType n . ceValueEnv)

-- | Extend the value environment with bindings.
withBindings :: [(Name, Type)] -> CheckM a -> CheckM a
withBindings bs = local (\env -> env { ceValueEnv = Env.extendMany bs (ceValueEnv env) })

-- | Extend type variable scope.
withTypeVars :: [(Name, Bound)] -> CheckM a -> CheckM a
withTypeVars tvs = local (\env -> env { ceTypeVars = Map.fromList tvs `Map.union` ceTypeVars env })

-- | Get TypeDefs from mutable state.
getTypeDefs :: CheckM TypeDefs
getTypeDefs = gets csTypeDefs

-- | Update TypeDefs in mutable state.
modifyTypeDefs :: (TypeDefs -> TypeDefs) -> CheckM ()
modifyTypeDefs f = modify (\s -> s { csTypeDefs = f (csTypeDefs s) })

-- | Add a subtype constraint: actual <: expected.
addConstraint :: Type -> Type -> CheckM ()
addConstraint actual expected =
    modify (\s -> s { csConstraints = Set.insert (actual ?<: expected) (csConstraints s) })

-- | Add an assumption (e.g. from generics bound).
addAssumption :: Type -> Type -> CheckM ()
addAssumption lower upper =
    modify (\s -> s { csAssumptions = Set.insert (lower ?<: upper) (csAssumptions s) })

-- | Take constraints and assumptions, resetting them.
takeConstraintsAndAssumptions :: CheckM (Set Constraint, Set Assumption)
takeConstraintsAndAssumptions = do
    cs <- gets csConstraints
    as <- gets csAssumptions
    modify (\s -> s { csConstraints = Set.empty, csAssumptions = Set.empty })
    pure (cs, as)

-- | Solve accumulated constraints and report errors.
solveAndReport :: SrcSpan -> CheckM ()
solveAndReport ann = do
    (cs, as) <- takeConstraintsAndAssumptions
    defs <- getTypeDefs
    case solve defs as cs of
        SolveSuccess         -> pure ()
        SolveContradiction msg -> emitError ann msg

-- | Add generics bound assumptions from a Bound.
addBoundAssumptions :: Name -> Bound -> CheckM ()
addBoundAssumptions name = \case
    BoundSub ty  -> addAssumption (TVar name) ty
    BoundSup ty  -> addAssumption ty (TVar name)
    BoundIs  ty  -> do
        addAssumption (TVar name) ty
        addAssumption ty (TVar name)
    BoundNone    -> pure ()

-- =========================================================================
-- Resolving source-level types to internal types
-- =========================================================================

-- | Resolve a source-level type expression to an internal Type.
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
    TyObject _ fields -> do
        fields' <- forM fields $ \(name, tyE) -> do
            ty <- resolveTyExpr tyE
            pure (name, ty)
        pure (TObject (Map.fromList fields'))
    TyTuple _ elems -> do
        tys <- mapM resolveTyExpr elems
        pure (TTuple tys)
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

-- | Resolve a type name to a Type.
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

-- | Resolve an effect type expression.
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

-- | Convert source type params to internal TypeParams + type var bindings.
resolveSrcTypeParams :: [SrcTypeParam ann] -> CheckM [(Name, Bound)]
resolveSrcTypeParams = mapM $ \stp -> do
    bound <- case stpBound stp of
        Nothing                 -> pure BoundNone
        Just (SrcBoundSub _ te) -> BoundSub <$> resolveTyExpr te
        Just (SrcBoundSup _ te) -> BoundSup <$> resolveTyExpr te
        Just (SrcBoundIs  _ te) -> BoundIs  <$> resolveTyExpr te
    pure (stpName stp, bound)

-- | Convert source data type params to variance + bound pairs.
resolveSrcDataTypeParams :: [SrcDataTypeParam ann] -> CheckM [(Name, Variance, Bound)]
resolveSrcDataTypeParams = mapM $ \sdtp -> do
    bound <- case sdtpBound sdtp of
        Nothing                 -> pure BoundNone
        Just (SrcBoundSub _ te) -> BoundSub <$> resolveTyExpr te
        Just (SrcBoundSup _ te) -> BoundSup <$> resolveTyExpr te
        Just (SrcBoundIs  _ te) -> BoundIs  <$> resolveTyExpr te
    let var = resolveSrcVariance (sdtpVariance sdtp)
    pure (sdtpName sdtp, var, bound)

-- | Convert source variance to internal Variance.
resolveSrcVariance :: SrcVariance -> Variance
resolveSrcVariance = \case
    SrcOut   -> Covariant
    SrcIn    -> Contravariant
    SrcInOut -> Bivariant
    SrcNone  -> Invariant


-- =========================================================================
-- Module checking
-- =========================================================================

-- | Check a module, returning accumulated diagnostics.
checkModule :: Module SrcSpan -> CheckM ()
checkModule m = do
    registerDecls (modDecls m)
    mapM_ checkDecl (modDecls m)

-- | Register type/data/effect declarations into TypeDefs (updates csTypeDefs).
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

    DeclData _ name sdtps fields -> do
        paramInfo <- resolveSrcDataTypeParams sdtps
        let tvBindings = map (\(n, _, b) -> (n, b)) paramInfo
        fieldTys <- withTypeVars tvBindings $ forM fields $ \(fname, ftyE) -> do
            fty <- resolveTyExpr ftyE
            pure (fname, fty)
        let paramNames = map (\(n, _, _) -> n) paramInfo
        let params = map (\(_, v, _) -> DataTypeParam { dtpVariance = v }) paramInfo
        let bounds = map (\(_, _, b) -> b) paramInfo
        let dd = DataDef
                { ddParamNames = paramNames
                , ddParams = params
                , ddBounds = bounds
                , ddFields = fieldTys
                }
        modifyTypeDefs $ \td -> td { tdData = Map.insert name dd (tdData td) }

    DeclEffect _ name sdtps fields retTyE -> do
        paramInfo <- resolveSrcDataTypeParams sdtps
        let tvBindings = map (\(n, _, b) -> (n, b)) paramInfo
        fieldTys <- withTypeVars tvBindings $ forM fields $ \(fname, ftyE) -> do
            fty <- resolveTyExpr ftyE
            pure (fname, fty)
        retTy <- withTypeVars tvBindings $ resolveTyExpr retTyE
        let params = map (\(_, v, _) -> DataTypeParam { dtpVariance = v }) paramInfo
        let bounds = map (\(_, _, b) -> b) paramInfo
        let ed = EffectDef
                { edParams   = params
                , edBounds   = bounds
                , edFields   = fieldTys
                , edReturnTy = retTy
                }
        modifyTypeDefs $ \td -> td { tdEffects = Map.insert name ed (tdEffects td) }

    _ -> pure ()

-- | Check a single declaration.
checkDecl :: Decl SrcSpan -> CheckM ()
checkDecl = \case
    DeclLet ann _target stps mTyAnn body -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            forM_ tvBindings $ \(n, bound) -> addBoundAssumptions n bound
            (bodyTy, _bodyEff) <- withFreshEffects $ inferExpr body
            case mTyAnn of
                Just tyAnn -> do
                    annTy <- resolveTyExpr tyAnn
                    addConstraint bodyTy annTy
                Nothing -> pure ()
            solveAndReport ann

    DeclFn ann _name stps params mRetTy fnBody -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            forM_ tvBindings $ \(n, bound) -> addBoundAssumptions n bound
            paramBindings <- forM params $ \p -> do
                ty <- resolveTyExpr (paramType p)
                pure (paramName p, ty)
            withBindings paramBindings $ do
                (bodyTy, _bodyEff) <- withFreshEffects $ inferFnBody fnBody
                case mRetTy of
                    Just retAnn -> do
                        retTy <- resolveTyExpr retAnn
                        addConstraint bodyTy retTy
                    Nothing -> pure ()
                solveAndReport ann

    DeclImport {} -> pure ()
    DeclType {} -> pure ()
    DeclData {} -> pure ()
    DeclEffect {} -> pure ()

-- =========================================================================
-- Expression type inference
-- =========================================================================

-- | Infer the type of an expression. Effects are accumulated in state.
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
        appliedFunTy <- applyGenericArgs ann funTy tyArgs
        checkFunApp ann appliedFunTy argTys

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
                        checkSubtype ann bodyTy rt
                        pure rt
                    Nothing -> pure bodyTy
                let effTy = denormalizeEffect bodyEff
                pure (TFun paramTypes retTy effTy)

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
        armTys <- forM arms $ \arm -> do
            bindings <- inferPattern scrutTy (maPat arm)
            withBindings bindings $ inferExpr (maBody arm)
        case armTys of
            []     -> pure TNever
            (t:ts) -> pure (foldl TUnion t ts)

    EHandle _ann expr cases mRet -> do
        (exprTy, exprEff) <- withFreshEffects $ inferExpr expr
        let caughtNames = Set.fromList (map hcEffect cases)
        addEffect (removeEffects caughtNames exprEff)
        case mRet of
            Just hr ->
                withBindings [(Name (unName (hrParam hr)), exprTy)] $
                    inferExpr (hrBody hr)
            Nothing -> pure exprTy

    EObject _ann mSpread fields -> do
        spreadFields <- case mSpread of
            Nothing -> pure Map.empty
            Just sExpr -> do
                sTy <- inferExpr sExpr
                pure (extractFields sTy)
        fieldTys <- forM fields $ \(name, val) -> do
            ty <- inferExpr val
            pure (name, ty)
        pure (TObject (Map.fromList fieldTys `Map.union` spreadFields))

    ETuple _ elems -> do
        tys <- forM elems $ \case
            TElem e  -> inferExpr e
            TSpread e -> inferExpr e
        pure (TTuple tys)

    EArray _ elems -> do
        tys <- forM elems $ \case
            AElem e  -> inferExpr e
            ASpread e -> do
                eTy <- inferExpr e
                case extractArrayElem eTy of
                    Just elemTy -> pure elemTy
                    Nothing     -> pure TUnknown
        case tys of
            []     -> pure (TArray TUnknown)
            (t:ts) -> pure (TArray (foldl TUnion t ts))

    EField _ obj fieldName -> do
        objTy <- inferExpr obj
        let fields = extractFields objTy
        case Map.lookup fieldName fields of
            Just fTy -> pure fTy
            Nothing  -> pure TUnknown

    EIndex _ arr idx -> do
        arrTy <- inferExpr arr
        _ <- inferExpr idx
        case extractArrayElem arrTy of
            Just elemTy -> pure elemTy
            Nothing     -> pure TUnknown

    EReturn _ mExpr -> do
        case mExpr of
            Just e  -> inferExpr e
            Nothing -> pure (TPrim PrimNull)

    ETemplateLit _ _ -> pure (TPrim PrimString)

    EBinOp ann op lhs rhs -> inferBinOp ann op lhs rhs

    EUnaryOp ann op expr -> inferUnaryOp ann op expr

-- | Infer type from a function body.
inferFnBody :: FnBody SrcSpan -> CheckM Type
inferFnBody = \case
    FnExpr e -> inferExpr e
    FnBlock _ stmts ->
        local (\env -> env { ceInFnBody = True }) $ inferBlock stmts

-- | Infer type from a block (list of statements).
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
        StmtLet _ target mTyAnn val -> do
            valTy <- inferExpr val
            ty <- case mTyAnn of
                Just tyAnn -> do
                    annTy <- resolveTyExpr tyAnn
                    addConstraint valTy annTy
                    pure annTy
                Nothing -> pure valTy
            bindings <- letTargetBindings target ty
            withBindings bindings $ go rest
        StmtReturn _ mE -> do
            case mE of
                Just e  -> inferExpr e
                Nothing -> pure (TPrim PrimNull)

-- | Validate return statement placement within a block.
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

-- | Get bindings from a let target.
letTargetBindings :: LetTarget SrcSpan -> Type -> CheckM [(Name, Type)]
letTargetBindings target ty =
    case target of
        LetName name -> pure [(name, ty)]
        LetPat pat   -> inferPattern ty pat

-- =========================================================================
-- Type extraction helpers (operate directly on Type)
-- =========================================================================

-- | Extract object fields from a Type.
-- Union → intersection of common fields (union of field types).
-- Intersection → union of all fields (intersection of common field types).
extractFields :: Type -> Map Name Type
extractFields = \case
    TObject fields    -> fields
    TIntersection a b -> Map.unionWith (\x y -> TIntersection x y) (extractFields a) (extractFields b)
    TUnion a b        ->
        let fa = extractFields a; fb = extractFields b
        in  Map.intersectionWith (\x y -> TUnion x y) fa fb
    _                 -> Map.empty

-- | Extract array element type from a Type.
extractArrayElem :: Type -> Maybe Type
extractArrayElem = \case
    TArray t          -> Just t
    TUnion a b        -> case (extractArrayElem a, extractArrayElem b) of
        (Just ea, Just eb) -> Just (TUnion ea eb)
        (Just ea, Nothing) -> Just ea
        (Nothing, Just eb) -> Just eb
        _                  -> Nothing
    TIntersection a b -> case (extractArrayElem a, extractArrayElem b) of
        (Just ea, Just eb) -> Just (TIntersection ea eb)
        _                  -> Nothing
    _                 -> Nothing

-- | Check if a type is integer-like (for numeric op result type).
isIntegerLike :: Type -> Bool
isIntegerLike = \case
    TPrim PrimInteger     -> True
    TLit (LitIntegerType _) -> True
    TUnion a b            -> isIntegerLike a && isIntegerLike b
    TIntersection a b     -> isIntegerLike a || isIntegerLike b
    _                     -> False

-- =========================================================================
-- Pattern type inference
-- =========================================================================

-- | Infer variable bindings from a pattern matched against a type.
inferPattern :: Type -> Pat SrcSpan -> CheckM [(Name, Type)]
inferPattern scrutTy = \case
    PVar _ name -> pure [(name, scrutTy)]
    PLit _ _    -> pure []
    PWild _     -> pure []
    PCon _ qn pats -> do
        defs <- getTypeDefs
        let conName = qnName qn
        case Map.lookup conName (tdData defs) of
            Just dd -> do
                let mDataArgs = extractDataArgs defs conName scrutTy
                case mDataArgs of
                    Just tyArgs -> do
                        let subst = Map.fromList (zip (ddParamNames dd) tyArgs)
                        let fieldTys = map (substituteTVars subst . snd) (ddFields dd)
                        concat <$> zipWithM inferPattern fieldTys pats
                    Nothing ->
                        case scrutTy of
                            TVar varName -> do
                                tvs <- asks ceTypeVars
                                case Map.lookup varName tvs of
                                    Just (BoundSub boundTy) ->
                                        inferPattern boundTy (PCon undefined qn pats)
                                    _ -> concat <$> mapM (inferPattern TUnknown) pats
                            _ -> concat <$> mapM (inferPattern TUnknown) pats
            Nothing -> concat <$> mapM (inferPattern TUnknown) pats

    PObject _ objPat -> do
        let objFields = extractFields scrutTy
        fieldBindings <- forM (opFields objPat) $ \(fname, pat) -> do
            let fTy = fromMaybe TUnknown (Map.lookup fname objFields)
            inferPattern fTy pat
        restBinding <- case opRest objPat of
            Nothing            -> pure []
            Just (_, restName) ->
                let matchedFields = Set.fromList (map fst (opFields objPat))
                    restFields = Map.filterWithKey (\k _ -> not (Set.member k matchedFields)) objFields
                 in pure [(restName, TObject restFields)]
        pure (concat fieldBindings ++ restBinding)

    PTuple _ spreadPat -> do
        let tupleTys = case scrutTy of
                TTuple ts -> ts
                _         -> []
        inferSpreadPat tupleTys spreadPat

    PArray _ spreadPat -> do
        let elemTy = case scrutTy of
                TArray t -> t
                _        -> TUnknown
        inferSpreadPat (repeat elemTy) spreadPat

-- | Extract type arguments for a data constructor from a Type AST.
extractDataArgs :: TypeDefs -> Name -> Type -> Maybe [Type]
extractDataArgs defs conName = collect
  where
    collect = \case
        TData n args | n == conName -> Just args
        TUnion a b -> case (collect a, collect b) of
            (Just argsA, Just argsB) -> Just (mergeArgs True argsA argsB)
            (Just argsA, Nothing)    -> Just argsA
            (Nothing, Just argsB)    -> Just argsB
            (Nothing, Nothing)       -> Nothing
        TIntersection a b -> case (collect a, collect b) of
            (Just argsA, Just argsB) -> Just (mergeArgs False argsA argsB)
            (Just argsA, Nothing)    -> Just argsA
            (Nothing, Just argsB)    -> Just argsB
            (Nothing, Nothing)       -> Nothing
        _ -> Nothing

    mergeArgs isUnion argsA argsB =
        case Map.lookup conName (tdData defs) of
            Just dd | length (ddParams dd) == length argsA
                    , length argsA == length argsB ->
                zipWith3 (mergeByV isUnion) (map dtpVariance (ddParams dd)) argsA argsB
            _ -> zipWith (\a b -> if isUnion then TUnion a b else TIntersection a b) argsA argsB

    mergeByV isUnion v a b = case (v, isUnion) of
        (Covariant,     True)  -> TUnion a b
        (Covariant,     False) -> TIntersection a b
        (Contravariant, True)  -> TIntersection a b
        (Contravariant, False) -> TUnion a b
        (Bivariant,     True)  -> TUnion a b
        (Bivariant,     False) -> TIntersection a b
        (Invariant,     _)     -> if a == b then a else TUnknown


-- | Infer bindings from a spread pattern given a list of element types.
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
            inferPattern (TTuple midTys) pat
    pure (beforeBindings ++ spreadBinding ++ afterBindings)

-- | zipWithM for lists.
zipWithM :: Monad m => (a -> b -> m c) -> [a] -> [b] -> m [c]
zipWithM f xs ys = mapM (uncurry f) (zip xs ys)

-- =========================================================================
-- Function application checking
-- =========================================================================

-- | Apply generic type arguments to a function type.
applyGenericArgs :: SrcSpan -> Type -> [Type] -> CheckM Type
applyGenericArgs _ann ty [] = pure ty
applyGenericArgs ann ty tyArgs = do
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
                    Just (BoundSub bound) -> addConstraint tyArg bound
                    Just (BoundSup bound) -> addConstraint bound tyArg
                    Just (BoundIs  bound) -> do
                        addConstraint tyArg bound
                        addConstraint bound tyArg
                    _                     -> pure ()
            pure (substituteTVars subst ty)

-- | Check function application: verify args <: params, return result type.
checkFunApp :: SrcSpan -> Type -> [Type] -> CheckM Type
checkFunApp ann funTy argTys = case funTy of
    TFun params ret eff -> do
        unless (length argTys == length params) $
            emitError ann $ "expected " <> T.pack (show (length params))
                <> " arguments, got " <> T.pack (show (length argTys))
        forM_ (zip argTys params) $ \(argTy, param) ->
            addConstraint argTy (fpType param)
        defs <- getTypeDefs
        addEffect (normalizeEffect defs eff)
        pure ret
    _ -> do
        emitError ann "not a function"
        pure TUnknown

-- =========================================================================
-- Subtype checking
-- =========================================================================

-- | Record a subtype constraint instead of checking immediately.
checkSubtype :: SrcSpan -> Type -> Type -> CheckM ()
checkSubtype _ann actual expected = addConstraint actual expected


-- =========================================================================
-- Binary / Unary operators
-- =========================================================================

inferBinOp :: SrcSpan -> BinOp -> Expr SrcSpan -> Expr SrcSpan -> CheckM Type
inferBinOp ann op lhs rhs = do
    lhsTy <- inferExpr lhs
    rhsTy <- inferExpr rhs
    case op of
        OpAdd  -> checkNumericOp ann lhsTy rhsTy
        OpSub  -> checkNumericOp ann lhsTy rhsTy
        OpMul  -> checkNumericOp ann lhsTy rhsTy
        OpDiv  -> checkNumericOp ann lhsTy rhsTy
        OpMod  -> checkNumericOp ann lhsTy rhsTy
        OpEq   -> pure (TPrim PrimBoolean)
        OpNeq  -> pure (TPrim PrimBoolean)
        OpLt   -> pure (TPrim PrimBoolean)
        OpLe   -> pure (TPrim PrimBoolean)
        OpGt   -> pure (TPrim PrimBoolean)
        OpGe   -> pure (TPrim PrimBoolean)
        OpAnd  -> pure (TPrim PrimBoolean)
        OpOr   -> pure (TPrim PrimBoolean)
        OpConcat -> do
            checkSubtype ann lhsTy (TPrim PrimString)
            checkSubtype ann rhsTy (TPrim PrimString)
            pure (TPrim PrimString)

checkNumericOp :: SrcSpan -> Type -> Type -> CheckM Type
checkNumericOp ann lhsTy rhsTy = do
    checkSubtype ann lhsTy (TPrim PrimNumber)
    checkSubtype ann rhsTy (TPrim PrimNumber)
    if isIntegerLike lhsTy && isIntegerLike rhsTy
        then pure (TPrim PrimInteger)
        else pure (TPrim PrimNumber)

inferUnaryOp :: SrcSpan -> UnaryOp -> Expr SrcSpan -> CheckM Type
inferUnaryOp ann op expr = do
    exprTy <- inferExpr expr
    case op of
        OpNeg -> do
            checkSubtype ann exprTy (TPrim PrimNumber)
            pure (TPrim PrimNumber)
        OpNot -> do
            checkSubtype ann exprTy (TPrim PrimBoolean)
            pure (TPrim PrimBoolean)

-- =========================================================================
-- Literal types
-- =========================================================================

-- | Infer the type of a literal (always a literal type, not a primitive).
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

-- | Convert normalized effect back to Effect.
denormalizeEffect :: NormalizedEffect -> Effect
denormalizeEffect = \case
    NEffPure -> EffPure
    NEffImpure -> EffImpure
    NEffSet refs -> case refs of
        []  -> EffPure
        [r] -> EffSingle (nerName r) (nerArgs r)
        rs  -> EffUnion (map (\r -> EffSingle (nerName r) (nerArgs r)) rs)
