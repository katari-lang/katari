module Katari.Data.Id where

import Data.Aeson (FromJSON (..), ToJSON (..))

newtype GenericId where
  GenericsId :: Int -> GenericId
  deriving (Eq, Ord, Show)

instance ToJSON GenericId where
  toJSON (GenericsId n) = toJSON n

instance FromJSON GenericId where
  parseJSON = fmap GenericsId . parseJSON
