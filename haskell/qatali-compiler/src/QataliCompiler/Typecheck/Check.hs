{- | Type checker for the Qatali language.

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

    -- * Re-exports from Infer
    inferExpr,

    -- * Re-exports from Monad
    CheckM,
    CheckEnv (..),
    CheckState (..),
    runCheck,
    runCheckWithDefs,
    runCheckWithInterfaces,
) where

import           Control.Monad                         (forM, forM_)
import           Control.Monad.Reader                  (asks)
import qualified Data.Map.Strict                       as Map

import           QataliCompiler.Name                   (Name (..), QualifiedName (..))
import           QataliCompiler.SrcLoc                 (SrcSpan)
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Type.Defs              (DataDef (..),
                                                        DataKind (..),
                                                        EffectDef (..),
                                                        ImplDef (..),
                                                        ModuleInterface (..),
                                                        TraitDef (..),
                                                        TypeDefs (..),
                                                        TypeSynDef (..),
                                                        mergeTypeDefs)
import           QataliCompiler.Type.Type
import           QataliCompiler.Typecheck.Infer        (inferExpr, inferFnBody)
import           QataliCompiler.Typecheck.Monad
import           QataliCompiler.Typecheck.Resolve      (resolveEffectExpr,
                                                        resolveSrcDataTypeParams,
                                                        resolveSrcTypeParams,
                                                        resolveTyExpr)

-- =========================================================================
-- Module checking
-- =========================================================================

checkModule :: Module SrcSpan -> CheckM ()
checkModule m = do
    -- 1. Register type/data/effect definitions + top-level value types
    registerDecls (modDecls m)
    -- 2. Pre-populate value env with registered top-level values
    valueDefs <- getValueDefs
    let valueBindings = [(n, ty) | (n, (ty, _)) <- Map.toList valueDefs]
    -- 3. Process imports and collect bindings from imported modules
    importBindings <- collectImportBindings (modDecls m)
    -- 4. Check all declarations with full value environment
    withBindings (importBindings ++ valueBindings) $
        mapM_ checkDecl (modDecls m)

-- | Collect value bindings from import declarations.
collectImportBindings :: [Decl SrcSpan] -> CheckM [(Name, Type)]
collectImportBindings decls = concat <$> mapM collectOne decls
  where
    collectOne (DeclImport _ann modPath _mAlias mItems) = do
        imported <- ceImportedModules <$> askEnv
        case Map.lookup modPath imported of
            Nothing    -> pure []
            Just iface -> case mItems of
                -- import { foo, bar } from "mod" → import specific names
                Just items ->
                    pure [(n, ty) | n <- items, Just ty <- [Map.lookup n (miValues iface)]]
                -- import "mod" / import "mod" as alias → no direct bindings
                -- (qualified access via lookupVarQualified)
                Nothing -> pure []
    collectOne _ = pure []

    askEnv = asks id

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

    DeclData _ _isPub name sdtps declKind fields -> do
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

    DeclEffect _ _isPub name sdtps fields retTyE -> do
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

    -- Register top-level function types for cross-declaration references
    DeclFn _ isPub name stps _traitAnnots params mRetTy _mEffTy _body -> do
        tvBindings <- resolveSrcTypeParams stps
        withTypeVars tvBindings $ do
            paramTypes <- forM params $ \p -> do
                ty <- resolveTyExpr (paramType p)
                pure (FunParam (paramName p) ty)
            retTy <- case mRetTy of
                Just retAnn -> resolveTyExpr retAnn
                Nothing     -> pure TUnknown
            let fnTy = TFun paramTypes retTy EffImpure
            registerValueDef name fnTy isPub

    -- Register top-level let bindings
    DeclLet _ isPub target stps mTyAnn _body -> do
        ty <- case mTyAnn of
            Just tyAnn -> do
                tvBindings <- resolveSrcTypeParams stps
                withTypeVars tvBindings $ resolveTyExpr tyAnn
            Nothing -> pure TUnknown
        case target of
            LetName n -> registerValueDef n ty isPub
            LetPat _  -> pure ()

    -- Import: merge type defs from imported module and register alias
    DeclImport _ann modPath mAlias _mItems -> do
        imported <- ceImportedModules <$> asks id
        case Map.lookup modPath imported of
            Nothing    -> pure ()
            Just iface -> do
                modifyTypeDefs (mergeTypeDefs (miTypeDefs iface))
                case mAlias of
                    Just _alias -> pure ()  -- alias handled at EVar lookup time
                    Nothing    -> pure ()

    -- Register trait definition + implicit callable function
    DeclTrait _ name sdtps fields retTyE -> do
        paramInfo <- resolveSrcDataTypeParams sdtps
        let tvBindings = map (\(n, _, b) -> (n, b)) paramInfo
        fieldTys <- withTypeVars tvBindings $ forM fields $ \p -> do
            ty <- resolveTyExpr (paramType p)
            pure (paramName p, ty)
        retTy <- withTypeVars tvBindings $ resolveTyExpr retTyE
        let paramNames = map (\(n, _, _) -> n) paramInfo
        let params = map (\(_, v, _) -> DataTypeParam { dtpVariance = v }) paramInfo
        let bounds = map (\(_, _, b) -> b) paramInfo
        let td = TraitDef
                { trParamNames = paramNames
                , trParams   = params
                , trBounds   = bounds
                , trFields   = fieldTys
                , trReturnTy = retTy
                }
        modifyTypeDefs $ \defs -> defs { tdTraits = Map.insert name td (tdTraits defs) }
        -- Trait also introduces a callable function:
        --   fn TraitName<T>(args) -> RetTy with impure
        let fnParams = map (\(fn, ft) -> FunParam fn ft) fieldTys
        registerValueDef name (TFun fnParams retTy EffImpure) True

    -- Register impl mapping
    DeclImpl _ fnName traitQn tyArgExprs -> do
        let traitName = qnName traitQn
        tyArgs <- mapM resolveTyExpr tyArgExprs
        let implDef = ImplDef
                { idFnName    = fnName
                , idTraitName = traitName
                , idTypeArgs  = tyArgs
                }
        modifyTypeDefs $ \defs -> defs { tdImpls = implDef : tdImpls defs }

    -- Register foreign fn type in value defs
    DeclForeignFn _ name params retTyE mEffTyE -> do
        paramTypes <- forM params $ \p -> do
            ty <- resolveTyExpr (paramType p)
            pure (FunParam (paramName p) ty)
        retTy <- resolveTyExpr retTyE
        eff <- case mEffTyE of
            Just effE -> resolveEffectExpr effE
            Nothing   -> pure EffPure
        registerValueDef name (TFun paramTypes retTy eff) True

    -- Derive: stub (full codegen happens at IR phase)
    DeclDerive {} -> pure ()
    DeclExport {} -> pure ()

checkDecl :: Decl SrcSpan -> CheckM ()
checkDecl = \case
    DeclLet ann _isPub _target stps mTyAnn body -> do
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

    DeclFn ann _isPub _name stps _traitAnnots params mRetTy _mEffTy fnBody -> do
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

    DeclImport    {} -> pure ()
    DeclExport    {} -> pure ()
    DeclType      {} -> pure ()
    DeclData      {} -> pure ()
    DeclEffect    {} -> pure ()
    DeclForeignFn {} -> pure ()
    DeclTrait     {} -> pure ()
    DeclImpl      {} -> pure ()
    DeclDerive    {} -> pure ()
