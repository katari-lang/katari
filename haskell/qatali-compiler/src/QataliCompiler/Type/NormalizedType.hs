{- | Normalized effect representation.

After normalization, effects are either pure, impure, or a flat
list of distinct single effects (no nesting).

Note: This module previously contained NormalizedType with category slots.
That representation has been removed — subtype checking now operates
directly on Type.  Only the effect normalization types remain.
-}
module QataliCompiler.Type.NormalizedType (
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
    | NEffImpure
    -- ^ Any effect (top)
    deriving (Eq, Ord, Show)

-- | A single named effect reference with type arguments.
data NormalizedEffectRef = NormalizedEffectRef
    { nerName :: !Name
    , nerArgs :: ![Type]
    }
    deriving (Eq, Ord, Show)
