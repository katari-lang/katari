{- | Normalized effect representation.

After normalization, effects are either pure, impure, or a flat
list of distinct single effects (no nesting).
-}
module QataliCompiler.Type.NormalizedEffect (
    -- * Normalized effect
    NormalizedEffect (..),
    NormalizedEffectRef (..),
) where

import           QataliCompiler.Name (Name)
import           QataliCompiler.Type.Type (Type)

-- ---------------------------------------------------------------------------
-- Normalized effect

{- | A normalized effect.

After normalization, effects are either pure, impure, or a flat
list of distinct single effects (no nesting).
-}
data NormalizedEffect
    = NEffPure
    -- ^ No effect
    | NEffSet ![NormalizedEffectRef]
    -- ^ Union of distinct effects (sorted, no duplicates)
    | NEffVar !Name
    -- ^ An effect type variable (preserved from EffVar)
    | NEffImpure
    -- ^ Any effect (top)
    deriving (Eq, Ord, Show)

-- | A single named effect reference with type arguments.
data NormalizedEffectRef = NormalizedEffectRef
    { nerName :: !Name
    , nerArgs :: ![Type]
    }
    deriving (Eq, Ord, Show)
