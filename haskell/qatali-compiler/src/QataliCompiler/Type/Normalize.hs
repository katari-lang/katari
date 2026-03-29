{- | Effect normalization.

Converts 'Effect' values to 'NormalizedEffect' (a flat, deduplicated
representation).
-}
module QataliCompiler.Type.Normalize (
    normalizeEffect,
    mergeNormEffect,
) where

import           Data.List                          (partition)

import           QataliCompiler.Type.Defs           (TypeDefs)
import           QataliCompiler.Type.NormalizedEffect  (NormalizedEffect (..),
                                                      NormalizedEffectRef (..))
import           QataliCompiler.Type.Type

-- ---------------------------------------------------------------------------
-- Effect normalization

-- | Normalize an effect.
normalizeEffect :: TypeDefs -> Effect -> NormalizedEffect
normalizeEffect _defs = go
  where
    go :: Effect -> NormalizedEffect
    go = \case
        EffPure      -> NEffPure
        EffImpure    -> NEffImpure
        EffVar name -> NEffVar name
        EffSingle name args ->
            NEffSet [NormalizedEffectRef name args]
        EffUnion effs ->
            let normed = map go effs
             in foldl mergeNormEffect NEffPure normed

-- | Merge two normalized effects (union).
mergeNormEffect :: NormalizedEffect -> NormalizedEffect -> NormalizedEffect
mergeNormEffect a b =
    case (a, b) of
        (NEffPure, b')           -> b'
        (a', NEffPure)           -> a'
        (NEffImpure, _)          -> NEffImpure
        (_, NEffImpure)          -> NEffImpure
        (NEffVar n1, NEffVar n2)
            | n1 == n2           -> NEffVar n1
            | otherwise          -> NEffImpure
        (NEffVar _, _)           -> NEffImpure
        (_, NEffVar _)           -> NEffImpure
        (NEffSet a', NEffSet b') -> NEffSet (mergeEffRefs a' b')

-- | Merge two lists of effect refs, combining same-name effects.
mergeEffRefs :: [NormalizedEffectRef] -> [NormalizedEffectRef] -> [NormalizedEffectRef]
mergeEffRefs as bs =
    case (as, bs) of
        ([], bs') -> bs'
        (as', []) -> as'
        (a:as', bs') ->
            let (matching, rest) = partition (\b' -> nerName b' == nerName a) bs'
                merged = case matching of
                    []    -> a
                    (m:_) -> NormalizedEffectRef (nerName a)
                                (zipWith TUnion (nerArgs a) (nerArgs m))
             in merged : mergeEffRefs as' rest
