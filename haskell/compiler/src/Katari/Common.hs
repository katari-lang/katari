module Katari.Common where

import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (catMaybes)
import Data.Set qualified as Set

-- \| right only or left only  ~>  keep
-- \| left and right  ~>  apply f
unionWithKeyM :: (Ord k, Monad m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
unionWithKeyM f leftMap rightMap = do
  let keys = Set.union (Map.keysSet leftMap) (Map.keysSet rightMap)
  Map.fromList . catMaybes
    <$> mapM
      ( \key -> case (Map.lookup key leftMap, Map.lookup key rightMap) of
          (Just leftValue, Just rightValue) -> do
            unionedValue <- f key leftValue rightValue
            pure $ Just (key, unionedValue)
          (Just leftValue, Nothing) -> pure $ Just (key, leftValue)
          (Nothing, Just rightValue) -> pure $ Just (key, rightValue)
          (Nothing, Nothing) -> pure Nothing
      )
      (Set.toList keys)

intersectWithKeyM :: (Ord k, Monad m) => (k -> a -> a -> m a) -> Map k a -> Map k a -> m (Map k a)
intersectWithKeyM f leftMap rightMap = do
  let keys = Set.intersection (Map.keysSet leftMap) (Map.keysSet rightMap)
  Map.fromList . catMaybes
    <$> mapM
      ( \key -> case (Map.lookup key leftMap, Map.lookup key rightMap) of
          (Just leftValue, Just rightValue) -> do
            intersectedValue <- f key leftValue rightValue
            pure $ Just (key, intersectedValue)
          _ -> pure Nothing
      )
      (Set.toList keys)

mapMaybeM :: (Monad m, Ord k) => (a -> m (Maybe b)) -> Map k a -> m (Map k b)
mapMaybeM f m = Map.fromList . catMaybes <$> mapM go (Map.toList m)
  where
    go (key, value) = do
      maybeValue <- f value
      pure $ (key,) <$> maybeValue
