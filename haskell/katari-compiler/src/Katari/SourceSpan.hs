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

-- | Smart constructor that ensures start ≤ end. Swaps the two positions
-- if they are reversed, preventing negative-length underlines in the
-- diagnostic renderer.
mkSourceSpan :: FilePath -> Position -> Position -> SourceSpan
mkSourceSpan path p1 p2
  | p1 <= p2 = SrcSpan {filePath = path, start = p1, end = p2}
  | otherwise = SrcSpan {filePath = path, start = p2, end = p1}

-- | Generic accessor for nodes that carry a source span. Implemented
-- uniformly by record-shaped nodes and by GADT sum types.
class HasSourceSpan node where
  sourceSpanOf :: node -> SourceSpan
