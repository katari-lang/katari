{- | Type simplification.

Simplifies a 'Type' in-place for efficiency.  This is purely an optimization;
'isSubtype' must work correctly without simplification.

Operations:
  * Flatten unions\/intersections
  * Remove identity and absorbing elements
  * Deduplicate
  * Subsume literals under primitives
  * Merge same-named data types by variance
  * Merge function types in unions
-}
module QataliCompiler.Type.Simplify (
    simplifyType,
    TypeCategory (..),
    typeCategory,
) where

import           Data.List                     (partition, sortBy, foldl')
import           Data.Ord                      (comparing)
import qualified Data.Set                      as Set

import           QataliCompiler.Type.Defs      (TypeDefs (..), getVariancesDef)
import           QataliCompiler.Type.Type

-- ---------------------------------------------------------------------------
-- Type category (for disjointness detection)

-- | Classify a type into a category for disjointness detection.
-- Returns Nothing for compound types (union, intersection, unknown, never, var).
data TypeCategory = CatNumber | CatString | CatBoolean | CatNull
                  | CatArray | CatFunction | CatData
    deriving (Eq)

typeCategory :: Type -> Maybe TypeCategory
typeCategory = \case
    TPrim PrimInteger  -> Just CatNumber
    TPrim PrimNumber   -> Just CatNumber
    TPrim PrimString   -> Just CatString
    TPrim PrimBoolean  -> Just CatBoolean
    TPrim PrimNull     -> Just CatNull
    TLit (LitIntegerType _) -> Just CatNumber
    TLit (LitNumberType _)  -> Just CatNumber
    TLit (LitStringType _)  -> Just CatString
    TLit (LitBooleanType _) -> Just CatBoolean
    TArray _   -> Just CatArray
    TFun {}    -> Just CatFunction
    TData {}   -> Just CatData
    _          -> Nothing

-- ---------------------------------------------------------------------------
-- Type simplification

-- | Simplify a type by flattening unions\/intersections, removing identity
-- and absorbing elements, deduplicating, subsuming literals under primitives,
-- merging same-named data types by variance, and merging function types.
simplifyType :: TypeDefs -> Type -> Type
simplifyType defs = go
  where
    go :: Type -> Type
    go = \case
        TUnion a b ->
            simplUnion (flattenUnion (TUnion (go a) (go b)))
        TIntersection a b ->
            simplIntersect (flattenIntersect (TIntersection (go a) (go b)))
        TFun ps r e ->
            TFun (map (\p -> p { fpType = go (fpType p) }) ps) (go r) e
        TArray t   -> TArray (go t)
        TData n args -> TData n (map go args)
        t -> t  -- TUnknown, TNever, TPrim, TLit, TVar

    -- Union simplification --------------------------------------------------

    simplUnion :: [Type] -> Type
    simplUnion elems =
        let noNever = filter (/= TNever) elems
        in if null noNever then TNever
           else if any (== TUnknown) noNever then TUnknown
           else let deduped   = nubOrdPreserve noNever
                    subsumed  = subsumePrimsUnion deduped
                    merged    = mergeDataInUnion subsumed
                    merged'   = mergeFunsInUnion merged
                in  rebuildUnion merged'

    -- Intersection simplification -------------------------------------------

    simplIntersect :: [Type] -> Type
    simplIntersect elems =
        let noUnknown = filter (/= TUnknown) elems
        in if null noUnknown then TUnknown
           else if any (== TNever) noUnknown then TNever
           else let deduped = nubOrdPreserve noUnknown
                in if hasDisjoint deduped then TNever
                   else let merged = mergeDataInIntersect deduped
                        in  rebuildIntersect merged

    -- Flatten ----------------------------------------------------------------

    flattenUnion :: Type -> [Type]
    flattenUnion (TUnion a b) = flattenUnion a ++ flattenUnion b
    flattenUnion t            = [t]

    flattenIntersect :: Type -> [Type]
    flattenIntersect (TIntersection a b) = flattenIntersect a ++ flattenIntersect b
    flattenIntersect t                   = [t]

    -- Rebuild ----------------------------------------------------------------

    rebuildUnion :: [Type] -> Type
    rebuildUnion []     = TNever
    rebuildUnion [t]    = t
    rebuildUnion (t:ts) = foldl' TUnion t ts

    rebuildIntersect :: [Type] -> Type
    rebuildIntersect []     = TUnknown
    rebuildIntersect [t]    = t
    rebuildIntersect (t:ts) = foldl' TIntersection t ts

    -- Dedup (preserving order) -----------------------------------------------

    nubOrdPreserve :: [Type] -> [Type]
    nubOrdPreserve = go' Set.empty
      where
        go' _ []     = []
        go' seen (x:xs)
            | Set.member x seen = go' seen xs
            | otherwise         = x : go' (Set.insert x seen) xs

    -- Primitive subsumption in union -----------------------------------------
    -- 1 | integer → integer, integer | number → number, etc.

    subsumePrimsUnion :: [Type] -> [Type]
    subsumePrimsUnion tys = filter (not . isSubsumed) tys
      where
        hasT t = t `elem` tys
        hasPrimNum  = hasT (TPrim PrimNumber)
        hasPrimInt  = hasT (TPrim PrimInteger)
        hasPrimStr  = hasT (TPrim PrimString)
        hasPrimBool = hasT (TPrim PrimBoolean)
        isSubsumed = \case
            TLit (LitIntegerType _) -> hasPrimInt || hasPrimNum
            TLit (LitNumberType _)  -> hasPrimNum
            TLit (LitStringType _)  -> hasPrimStr
            TLit (LitBooleanType _) -> hasPrimBool
            TPrim PrimInteger       -> hasPrimNum
            _                       -> False

    -- Disjoint check ---------------------------------------------------------

    hasDisjoint :: [Type] -> Bool
    hasDisjoint tys =
        let cats = [c | t <- tys, Just c <- [typeCategory t]]
        in  case cats of
            []    -> False
            (c:cs) -> any (/= c) cs

    -- Data type merge --------------------------------------------------------
    -- Foo<A> | Foo<B> → Foo<A|B> (covariant), etc.

    mergeDataInUnion :: [Type] -> [Type]
    mergeDataInUnion = mergeDataInList True

    mergeDataInIntersect :: [Type] -> [Type]
    mergeDataInIntersect = mergeDataInList False

    mergeDataInList :: Bool -> [Type] -> [Type]
    mergeDataInList isUnion tys =
        let (datas, rest) = partition isDataTy tys
            grouped = groupByDataName datas
            merged  = concatMap (mergeDataGroup isUnion) grouped
        in rest ++ merged

    isDataTy :: Type -> Bool
    isDataTy (TData _ _) = True
    isDataTy _           = False

    groupByDataName :: [Type] -> [[Type]]
    groupByDataName = groupByEq dataName . sortBy (comparing dataName)
      where
        dataName (TData n _) = n
        dataName _           = error "groupByDataName: not TData"

    groupByEq :: Eq b => (a -> b) -> [a] -> [[a]]
    groupByEq _ [] = []
    groupByEq f (x:xs) =
        let (same, rest) = span (\y -> f y == f x) xs
        in (x:same) : groupByEq f rest

    mergeDataGroup :: Bool -> [Type] -> [Type]
    mergeDataGroup _ []  = []
    mergeDataGroup _ [t] = [t]
    mergeDataGroup isUnion group = foldl' tryMergeInto [] group
      where
        tryMergeInto acc t = case findAndMerge acc t of
            Just acc' -> acc'
            Nothing   -> acc ++ [t]

        findAndMerge [] _ = Nothing
        findAndMerge (x:xs) t = case tryMergeTwo isUnion x t of
            Just merged -> Just (merged : xs)
            Nothing     -> case findAndMerge xs t of
                Just xs' -> Just (x : xs')
                Nothing  -> Nothing

    tryMergeTwo :: Bool -> Type -> Type -> Maybe Type
    tryMergeTwo isUnion (TData n1 args1) (TData n2 args2)
        | n1 == n2, length args1 == length args2 =
            let vs = getVariancesDef defs n1 (length args1)
                merged = zipWith3 (mergeArgByVar isUnion) vs args1 args2
            in case sequence merged of
                Just args' -> Just (TData n1 (map go args'))
                Nothing    -> Nothing
        | otherwise = Nothing
    tryMergeTwo _ _ _ = Nothing

    mergeArgByVar :: Bool -> Variance -> Type -> Type -> Maybe Type
    mergeArgByVar _ _ a b | a == b = Just a
    mergeArgByVar isUnion v a b = case (v, isUnion) of
        (Covariant,     True)  -> Just (TUnion a b)
        (Covariant,     False) -> Just (TIntersection a b)
        (Contravariant, True)  -> Just (TIntersection a b)
        (Contravariant, False) -> Just (TUnion a b)
        (Bivariant,     _)     -> Just a  -- phantom param
        (Invariant,     _)     -> Nothing  -- can't merge

    -- Function merge in union ------------------------------------------------
    -- ((T) => U) | ((V) => A) → (T & V) => U | A

    mergeFunsInUnion :: [Type] -> [Type]
    mergeFunsInUnion tys =
        let (funs, rest) = partition isFunTy tys
            grouped = groupByEq funArity funs
            merged  = map (foldl1 mergeTwoFuns) grouped
        in rest ++ merged
      where
        isFunTy (TFun _ _ _) = True
        isFunTy _            = False
        funArity (TFun ps _ _) = length ps
        funArity _             = 0

    mergeTwoFuns :: Type -> Type -> Type
    mergeTwoFuns (TFun ps1 r1 e1) (TFun ps2 r2 e2)
        | length ps1 == length ps2 =
            let params = zipWith mergeParam ps1 ps2
                ret    = go (TUnion r1 r2)
                eff    = mergeEffs e1 e2
            in TFun params ret eff
    mergeTwoFuns a b = TUnion a b  -- fallback

    mergeParam :: FunParam -> FunParam -> FunParam
    mergeParam p1 p2 = FunParam
        { fpName = fpName p1
        , fpType = go (TIntersection (fpType p1) (fpType p2))
        }

    mergeEffs :: Effect -> Effect -> Effect
    mergeEffs EffPure   e        = e
    mergeEffs e         EffPure  = e
    mergeEffs EffImpure _        = EffImpure
    mergeEffs _         EffImpure = EffImpure
    mergeEffs e1        e2       = EffUnion [e1, e2]
