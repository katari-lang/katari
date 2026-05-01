module Katari.SourceSpan where

import Data.Aeson (FromJSON, ToJSON)
import GHC.Generics (Generic)

data Position = Position
  { line :: Int,
    column :: Int
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON Position

instance FromJSON Position

data SourceSpan = SrcSpan
  { filePath :: FilePath,
    start :: Position,
    end :: Position
  }
  deriving (Eq, Ord, Show, Generic)

instance ToJSON SourceSpan

instance FromJSON SourceSpan

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan
