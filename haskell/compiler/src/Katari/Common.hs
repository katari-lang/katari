module Katari.Common where

import Data.Map (Map)
import Data.Map.Merge.Strict qualified as Merge

-- | right only or left only  ~>  keep
--   left and right  ~>  apply f
unionWithKeyM :: (Ord k, Applicative m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
unionWithKeyM f = Merge.mergeA Merge.preserveMissing Merge.preserveMissing (Merge.zipWithAMatched f)

-- | left and right  ~>  apply f
--   otherwise  ~>  drop
intersectWithKeyM :: (Ord k, Applicative m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
intersectWithKeyM f = Merge.mergeA Merge.dropMissing Merge.dropMissing (Merge.zipWithAMatched f)
