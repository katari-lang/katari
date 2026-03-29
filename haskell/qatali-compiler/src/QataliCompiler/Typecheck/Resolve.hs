{- | Resolving source-level type expressions to internal types.

Converts 'TyExpr' (the parser output) into 'Type' and 'Effect' values,
looking up type synonyms, data types, effects, built-in primitives, and
type variables from the environment.
-}
module QataliCompiler.Typecheck.Resolve (
    resolveTyExpr,
    resolveTypeName,
    resolveEffectExpr,
    resolveSrcTypeParams,
    resolveSrcDataTypeParams,
    resolveSrcVariance,
) where

import           Control.Monad                         (forM)
import           Control.Monad.Reader                  (asks)
import qualified Data.Map.Strict                       as Map

import           QataliCompiler.Name                   (Name (..),
                                                        QualifiedName (..))
import           QataliCompiler.SrcLoc                 (SrcSpan)
import           QataliCompiler.Syntax.AST
import           QataliCompiler.Type.Defs              (TypeDefs (..),
                                                        TypeSynDef (..))
import           QataliCompiler.Type.Type
import           QataliCompiler.Typecheck.Monad

-- =========================================================================
-- Resolving source-level types to internal types
-- =========================================================================

resolveTyExpr :: TyExpr SrcSpan -> CheckM Type
resolveTyExpr = \case
    TyVar _ name -> pure (TVar name)
    TyCon ann qn -> resolveTypeName ann qn
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

resolveTypeName :: SrcSpan -> QualifiedName -> CheckM Type
resolveTypeName sp qn = do
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
                            _         -> do
                                emitError sp ("unknown type name: " <> unName name)
                                pure TUnknown

resolveEffectExpr :: TyExpr SrcSpan -> CheckM Effect
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

resolveSrcTypeParams :: [SrcTypeParam SrcSpan] -> CheckM [(Name, Bound)]
resolveSrcTypeParams = mapM $ \stp -> do
    bound <- case stpBound stp of
        Nothing                 -> pure BoundNone
        Just (SrcBoundSub _ te) -> BoundSub <$> resolveTyExpr te
        Just (SrcBoundSup _ te) -> BoundSup <$> resolveTyExpr te
        Just (SrcBoundIs  _ te) -> BoundIs  <$> resolveTyExpr te
    pure (stpName stp, bound)

resolveSrcDataTypeParams :: [SrcDataTypeParam SrcSpan] -> CheckM [(Name, Variance, Bound)]
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
    SrcInOut -> Invariant
    SrcNone  -> Bivariant
