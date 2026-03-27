{- | Type definitions and effect normalization.

This module holds:
  * 'TypeDefs' — the registry of all type\/data\/effect declarations
  * Effect normalization — converting 'Effect' to 'NormalizedEffect'

Type normalization (Type → NormalizedType) has been removed.
Subtype checking now operates directly on 'Type'.
-}
module QataliCompiler.Type.Normalize (
    TypeDefs (..),
    DataDef (..),
    TypeSynDef (..),
    EffectDef (..),
    normalizeEffect,
) where

import           Data.Map.Strict                    (Map)

import           QataliCompiler.Name                (Name)
import           QataliCompiler.Type.NormalizedType  (NormalizedEffect (..),
                                                      NormalizedEffectRef (..))
import           QataliCompiler.Type.Type

-- ---------------------------------------------------------------------------
-- Type definitions environment

-- | A data type definition (name + variance per param + bound per param).
data DataDef = DataDef
    { ddParamNames :: ![Name]
    -- ^ Type parameter names (for substitution)
    , ddParams     :: ![DataTypeParam]
    -- ^ One per type argument; variance only
    , ddBounds     :: ![Bound]
    -- ^ Bound for each type argument (parallel to ddParams)
    , ddFields     :: ![(Name, Type)]
    -- ^ Constructor fields
    }
    deriving (Show)

-- | A type synonym definition.
data TypeSynDef = TypeSynDef
    { tsParams :: ![TypeParam]
    , tsBody   :: !Type
    }
    deriving (Show)

-- | An effect definition.
data EffectDef = EffectDef
    { edParams   :: ![DataTypeParam]
    , edBounds   :: ![Bound]
    , edFields   :: ![(Name, Type)]
    , edReturnTy :: !Type
    }
    deriving (Show)

-- | All type\/data\/effect definitions in scope.
data TypeDefs = TypeDefs
    { tdData    :: !(Map Name DataDef)
    , tdTypes   :: !(Map Name TypeSynDef)
    , tdEffects :: !(Map Name EffectDef)
    }
    deriving (Show)

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
        EffVar _name -> NEffImpure
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
        (NEffSet a', NEffSet b') -> NEffSet (mergeEffRefs a' b')

-- | Merge two lists of effect refs, combining same-name effects.
mergeEffRefs :: [NormalizedEffectRef] -> [NormalizedEffectRef] -> [NormalizedEffectRef]
mergeEffRefs as bs =
    case (as, bs) of
        ([], bs') -> bs'
        (as', []) -> as'
        (a:as', bs') ->
            let (matching, rest) = partition' (\b -> nerName b == nerName a) bs'
                merged = case matching of
                    []    -> a
                    (m:_) -> NormalizedEffectRef (nerName a)
                                (zipWith TUnion (nerArgs a) (nerArgs m))
             in merged : mergeEffRefs as' rest
  where
    partition' _ [] = ([], [])
    partition' p (x:xs) =
        let (ys, ns) = partition' p xs
         in if p x then (x:ys, ns) else (ys, x:ns)
