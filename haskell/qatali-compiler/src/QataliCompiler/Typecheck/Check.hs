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
) where

import           Control.Monad                         (forM, forM_)
import qualified Data.Map.Strict                       as Map

import           QataliCompiler.SrcLoc                 (SrcSpan)
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Type.Defs              (DataDef (..),
                                                        DataKind (..),
                                                        EffectDef (..),
                                                        TypeDefs (..),
                                                        TypeSynDef (..))
import           QataliCompiler.Type.Type
import           QataliCompiler.Typecheck.Infer        (inferExpr, inferFnBody)
import           QataliCompiler.Typecheck.Monad
import           QataliCompiler.Typecheck.Resolve

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
