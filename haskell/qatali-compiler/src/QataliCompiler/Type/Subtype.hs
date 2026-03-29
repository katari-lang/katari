{- | Subtype judgment on Type values directly (no NormalizedType).

Subtyping operates on the Type AST.  Union/intersection are decomposed
using standard lattice rules:

  * @A | B <: C@  ↔  @A <: C@ ∧ @B <: C@
  * @A <: B & C@  ↔  @A <: B@ ∧ @A <: C@
  * @A <: B | C@  ↔  @A <: B@ ∨ @A <: C@
  * @A & B <: C@  ↔  @A <: C@ ∨ @B <: C@
-}
module QataliCompiler.Type.Subtype (
    isSubtype,
    isEffectSubtype,
) where

import           QataliCompiler.Type.Normalize      (TypeDefs (..),
                                                      normalizeEffect,
                                                      typeCategory,
                                                      getVariancesDef)
import           QataliCompiler.Type.NormalizedType  (NormalizedEffect (..),
                                                      NormalizedEffectRef (..))
import           QataliCompiler.Type.Type

-- ---------------------------------------------------------------------------
-- Subtype judgment

-- | Check whether @a <: b@ (a is a subtype of b), operating directly on Type.
isSubtype :: TypeDefs -> Type -> Type -> Bool
isSubtype defs = go
  where
    go a b = case (a, b) of
        -- top/bottom
        (_, TUnknown)  -> True
        (TNever, _)    -> True
        (TUnknown, _)  -> False
        (_, TNever)    -> False

        -- same type (catches literals, prims, TVars, etc.)
        _ | a == b     -> True

        -- Union on left: A | B <: C  ↔  A <: C ∧ B <: C
        (TUnion a1 a2, _) -> go a1 b && go a2 b

        -- Intersection on right: A <: B & C  ↔  A <: B ∧ A <: C
        (_, TIntersection b1 b2) -> go a b1 && go a b2

        -- Union on right: A <: B | C  ↔  A <: B ∨ A <: C
        (_, TUnion b1 b2) -> go a b1 || go a b2

        -- Intersection on left: simplify first, then check
        (TIntersection a1 a2, _) ->
            case simplifyIntersect a1 a2 of
                TNever -> True  -- never <: anything
                simplified | simplified /= a -> go simplified b
                _ -> go a1 b || go a2 b

        -- Primitive hierarchy:  literal <: prim <: wider prim
        (TLit (LitIntegerType _), TPrim PrimInteger) -> True
        (TLit (LitIntegerType _), TPrim PrimNumber)  -> True
        (TLit (LitNumberType _),  TPrim PrimNumber)  -> True
        (TLit (LitStringType _),  TPrim PrimString)  -> True
        (TLit (LitBooleanType _), TPrim PrimBoolean) -> True
        (TPrim PrimInteger, TPrim PrimNumber)         -> True

        -- Function: params contravariant, return covariant, effect covariant
        (TFun ps1 r1 e1, TFun ps2 r2 e2) ->
            length ps1 == length ps2 &&
            all (\(p1, p2) -> go (fpType p2) (fpType p1)) (zip ps1 ps2) &&
            go r1 r2 &&
            isEffectSubtype defs (normalizeEffect defs e1) (normalizeEffect defs e2)

        -- Array: covariant
        (TArray e1, TArray e2) -> go e1 e2

        -- Data: same name → variance-based; different name → false
        (TData n1 args1, TData n2 args2)
            | n1 == n2, length args1 == length args2 ->
                let vs = getVariancesDef defs n1 (length args1)
                in  and [isSubByVariance defs v a' b' | (v, a', b') <- zip3 vs args1 args2]
            | otherwise -> False

        -- Everything else: not a subtype
        _ -> False

-- | Simplify an intersection of two types.
-- Detects disjoint types (→ never).
simplifyIntersect :: Type -> Type -> Type
simplifyIntersect a b
    -- Disjoint categories → never
    | Just ca <- typeCategory a, Just cb <- typeCategory b, ca /= cb = TNever
    -- Cannot simplify
    | otherwise = TIntersection a b

-- | Check subtype relationship according to variance.
isSubByVariance :: TypeDefs -> Variance -> Type -> Type -> Bool
isSubByVariance defs v a b = case v of
    Covariant     -> isSubtype defs a b
    Contravariant -> isSubtype defs b a
    Invariant     -> isSubtype defs a b && isSubtype defs b a
    Bivariant     -> True


-- ---------------------------------------------------------------------------
-- Effect subtyping (operates on NormalizedEffect — kept as-is)

-- | Check whether effect @a <: b@.
isEffectSubtype :: TypeDefs -> NormalizedEffect -> NormalizedEffect -> Bool
isEffectSubtype _defs effA effB =
    case (effA, effB) of
        (NEffPure, _)         -> True
        (_, NEffImpure)       -> True
        (NEffImpure, NEffSet _) -> False
        (NEffImpure, NEffPure)  -> False
        (NEffSet _, NEffPure)   -> False
        (NEffSet as, NEffSet bs) ->
            all (\a -> any (isEffRefSubtype a) bs) as

-- | Check whether a single effect ref is a subtype of another.
isEffRefSubtype :: NormalizedEffectRef -> NormalizedEffectRef -> Bool
isEffRefSubtype a b =
    nerName a == nerName b &&
    length (nerArgs a) == length (nerArgs b) &&
    nerArgs a == nerArgs b
