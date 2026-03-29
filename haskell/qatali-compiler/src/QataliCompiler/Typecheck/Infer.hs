{- | Expression type inference for the Qatali type checker.

HM-style inference: generates fresh unknowns and constraints
that are resolved by the solver.  Also handles pattern matching,
binary\/unary operators, and effect denormalization.
-}
module QataliCompiler.Typecheck.Infer (
    inferExpr,
    inferFnBody,
    inferPattern,
) where

import           Control.Monad                         (forM, forM_, unless, zipWithM)
import           Control.Monad.Reader                  (asks, local)
import qualified Data.Map.Strict                       as Map
import           Data.Maybe                            (fromMaybe)
import qualified Data.Set                              as Set
import qualified Data.Text                             as T

import           QataliCompiler.Name                   (Name (..),
                                                        QualifiedName (..))
import           QataliCompiler.SrcLoc                 (SrcSpan (..))
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Type.Defs              (DataDef (..),
                                                        DataKind (..),
                                                        EffectDef (..),
                                                        TypeDefs (..))
import           QataliCompiler.Type.Normalize         (normalizeEffect)
import           QataliCompiler.Type.NormalizedEffect    (NormalizedEffect (..),
                                                        NormalizedEffectRef (..))
import           QataliCompiler.Type.Type
import           QataliCompiler.Typecheck.Monad
import           QataliCompiler.Typecheck.Resolve

-- =========================================================================
-- Expression type inference
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
-- Effect denormalization
-- =========================================================================

denormalizeEffect :: NormalizedEffect -> Effect
denormalizeEffect = \case
    NEffPure -> EffPure
    NEffImpure -> EffImpure
    NEffVar n -> EffVar n
    NEffSet refs -> case refs of
        []  -> EffPure
        [r] -> EffSingle (nerName r) (nerArgs r)
        rs  -> EffUnion (map (\r -> EffSingle (nerName r) (nerArgs r)) rs)
